#!/usr/bin/env bash
# test-remote-sshd-keys-gone.sh — the supervisor must not outlive its own
# credential store (your-org/nexus-code#1034 recommendation 4).
#
# THE ORPHAN #1034 FOUND was a live sshd whose AuthorizedKeysFile pointed into
# a directory that had since been reaped — a listening endpoint that could
# authenticate nobody, reachable only because an UNRELATED cleanup happened to
# take its keys. Had the directory survived, so would an auth surface no one
# was accountable for. `remote-sshd-supervised.sh` now re-checks the store on
# every supervision tick and, when it is gone, stops sshd and EXITS 78 rather
# than serving on.
#
# Three arms, one variable each, against a FAKE sshd (REMOTE_SSHD_BIN) so no
# port is opened and no real daemon is involved:
#
#   1. authorized_keys existed at launch and is REMOVED mid-run  -> exit 78,
#      the reason logged, the fake sshd TERMinated
#   2. the whole principals dir is REMOVED mid-run                -> exit 78
#   3. CONTROL: nothing removed                                   -> still
#      running after the same interval (then reaped by this suite)
#
# The store lives under $HOME/.claude, unique per pid, because
# `_remote_principals_guard` correctly refuses anywhere else.
#
# Run: bash monitor/watcher/test-remote-sshd-keys-gone.sh
# Expected: ALL TESTS PASSED, exit 0.
set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
SUP="$MON_DIR/remote-sshd-supervised.sh"
HEALTH="$MON_DIR/remote-ssh-health.sh"
[[ -x "$SUP" || -r "$SUP" ]] || th_abort "missing $SUP"

WORK=$(mktemp -d -t nexus-keysgone-1034-XXXXXX) || th_abort "mktemp failed"
PRINCIPALS_BASE="$HOME/.claude/principals-keysgone-$$"
CHILD_PIDS=()
cleanup() {
    local p
    for p in "${CHILD_PIDS[@]:-}"; do
        [[ -n "$p" ]] || continue
        th_kill_own_child "$p" KILL 2>/dev/null
        wait "$p" 2>/dev/null
    done
    rm -rf "$WORK" "$PRINCIPALS_BASE"*
}
trap cleanup EXIT
mkdir -p "$WORK/state" "$HOME/.claude"; chmod 700 "$HOME/.claude"

cat >"$WORK/nexus.yml" <<'YML'
monitor:
  remote:
    bind_address: 127.0.0.1
    from_cidr: ""
YML
export NEXUS_CONFIG="$WORK/nexus.yml"
export NEXUS_ROOT="$WORK"
export NEXUS_STATE_DIR="$WORK/state"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
export MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1
export MONITOR_REMOTE_PORT=22999
export REMOTE_SSHD_RESTART_DELAY=1
export REMOTE_SSHD_RESTART_DELAY_MAX=2
export REMOTE_SSHD_GATE_RECHECK=1
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    nexus-remote-ssh "$NEXUS_ROOT" "$SUP" "$HEALTH" "$WORK/remote-ssh.log" emit-only \
    > "$NEXUS_SERVICES_REGISTRY"

# The FAKE sshd: records its pid, notes a TERM, never listens.
FAKE="$WORK/fake-sshd"
cat > "$FAKE" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FAKE_MARK"
trap 'printf "TERM\n" >> "$FAKE_MARK.sig"; exit 0' TERM
while :; do sleep 1; done
FAKE
chmod +x "$FAKE"
export REMOTE_SSHD_BIN="$FAKE"

mk_store() {   # mk_store <dir> — a store the guards accept: 0700, 0600 host key, empty authorized_keys
    mkdir -p "$1"; chmod 700 "$1"
    printf 'not-a-real-key\n' > "$1/ssh_host_ed25519_key"; chmod 600 "$1/ssh_host_ed25519_key"
    : > "$1/authorized_keys"; chmod 600 "$1/authorized_keys"
}

wait_for() {   # wait_for <path> <seconds>
    local i=0 ticks=$(( $2 * 10 ))
    while (( i++ < ticks )); do [[ -e "$1" ]] && return 0; sleep 0.1; done
    [[ -e "$1" ]]
}

# run_case <name> <mutation-command...>: launch the supervisor (bounded), wait
# for the fake sshd, apply the mutation, wait for the supervisor to exit.
# Sets CASE_RC (124 = still running at the bound), CASE_LOG, CASE_MARK.
run_case() {
    local name="$1"; shift
    local store="$PRINCIPALS_BASE-$name"
    mk_store "$store"
    CASE_LOG="$WORK/$name.log"; CASE_MARK="$WORK/$name.mark"
    rm -f "$CASE_MARK" "$CASE_MARK.sig"
    MONITOR_REMOTE_PRINCIPALS_DIR="$store" FAKE_MARK="$CASE_MARK" \
        timeout 25 bash "$SUP" >"$CASE_LOG" 2>&1 &
    local sup=$!
    CHILD_PIDS+=( "$sup" )
    if ! wait_for "$CASE_MARK" 15; then
        CASE_RC=-1
        return
    fi
    "$@"    # the mutation
    local i=0
    while (( i++ < 150 )) && kill -0 "$sup" 2>/dev/null; do sleep 0.1; done
    if kill -0 "$sup" 2>/dev/null; then
        CASE_RC=124   # still running after 15s: the case's own bound, not timeout's
        return
    fi
    wait "$sup"; CASE_RC=$?
}

echo "== 1. authorized_keys REMOVED mid-run -> stop sshd, exit 78"
rm_keys() { rm -f "$PRINCIPALS_BASE-keys/authorized_keys"; }
run_case keys rm_keys
assert_eq "fixture staged: the fake sshd started under the supervisor" "$([[ -s "$CASE_MARK" ]] && echo yes || echo no)" "yes"
assert_eq "the supervisor EXITS (78) once its AuthorizedKeysFile is gone — it did not keep serving" "$CASE_RC" "78"
assert_contains "…and logs the reason, naming the file" "$(cat "$CASE_LOG")" "AuthorizedKeysFile $PRINCIPALS_BASE-keys/authorized_keys existed at launch and is GONE"
assert_contains "…and the issue" "$(cat "$CASE_LOG")" "your-org/nexus-code#1034 rec. 4"
assert_eq "…and the fake sshd was TERMinated, not abandoned" "$([[ -s "$CASE_MARK.sig" ]] && sed -n '1p' "$CASE_MARK.sig" || echo none)" "TERM"

echo "== 2. the whole principals dir REMOVED mid-run -> exit 78"
rm_store() { rm -rf "$PRINCIPALS_BASE-store"; }
run_case store rm_store
assert_eq "fixture staged: the fake sshd started" "$([[ -s "$CASE_MARK" ]] && echo yes || echo no)" "yes"
assert_eq "a reaped principals dir (the #1034 shape) -> exit 78" "$CASE_RC" "78"
assert_contains "…naming the directory" "$(cat "$CASE_LOG")" "principals_dir $PRINCIPALS_BASE-store is GONE"
assert_eq "…and sshd was TERMinated" "$([[ -s "$CASE_MARK.sig" ]] && sed -n '1p' "$CASE_MARK.sig" || echo none)" "TERM"

echo "== 3. CONTROL: nothing removed -> the supervisor keeps serving"
noop() { sleep 4; }
run_case control noop
assert_eq "fixture staged: the fake sshd started" "$([[ -s "$CASE_MARK" ]] && echo yes || echo no)" "yes"
assert_eq "with the store intact the supervisor is STILL RUNNING after the same interval (rc bound = 124)" "$CASE_RC" "124"
assert_not_contains "…and nothing about a missing store was logged" "$(cat "$CASE_LOG")" "is GONE"
assert_eq "…and sshd was NOT signalled" "$([[ -e "$CASE_MARK.sig" ]] && echo signalled || echo untouched)" "untouched"

th_summary_and_exit
