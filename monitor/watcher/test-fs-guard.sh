#!/usr/bin/env bash
# test-fs-guard.sh — read-only-filesystem guard (your-org/nexus-code#473).
#
# Both-directions suite. Every case here FAILS on pre-fix `dev` and PASSES
# on the branch; the PR body records the measured counts.
#
# T2 is the one that pins the actual bug: a probe that writes through an
# already-open fd reports HEALTHY during a total outage, because an open fd
# survives its mount being detached. It asserts BOTH facts in one test —
# the held fd still writes AND the probe still says not-writable — so it
# also fails any "fix" that caches an fd.
#
# HERMETIC. A 0555 fixture directory stands in for a read-only mount: the
# probe is errno-agnostic (EACCES from mode bits, EROFS from a RO mount,
# ENOSPC from a full disk are all "cannot write here"), so it exercises the
# identical code path. The real project tree is NEVER made read-only, and
# nothing outside $WORK / $TMPDIR is written.
#
# your-org/nexus-code#256 guard: a bare `$NEXUS_ROOT` under `set -u` passes
# in-sandbox (where it is exported) and dies on a clean CI runner. This test
# re-execs itself with those variables UNSET so the fixtures cannot be
# silently served by the operator's real tree.

set -uo pipefail

if [[ -z "${_FS_GUARD_TEST_REEXEC:-}" ]]; then
    export _FS_GUARD_TEST_REEXEC=1
    exec env -u NEXUS_ROOT -u NEXUS_LOCALS -u NEXUS_STATE_DIR \
        bash "${BASH_SOURCE[0]}" "$@"
fi

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_dir/../.." && pwd)

# shellcheck source=monitor/watcher/_lib.sh
source "$_dir/_lib.sh"
# shellcheck source=monitor/watcher/_fs_guard.sh
source "$_dir/_fs_guard.sh"

WORK=$(mktemp -d)
# 0555 fixtures must be made writable again before rm can recurse them.
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# root ignores mode bits, so a 0555 dir is still writable for it.
_can_test_ro=1
[[ "$(id -u)" == "0" ]] && _can_test_ro=0
if (( ! _can_test_ro )); then
    echo "SKIP: running as root — 0555 fixtures cannot model a read-only mount" >&2
    th_summary_and_exit
fi

# ---- stubs -----------------------------------------------------------------
STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/sandbox-notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NOTIFY_LOG:-/dev/null}"
exit 0
EOF

# `tmux` stub — the escalation touches tmux (display-message, and send-keys
# as a last resort). It must never reach the operator's real session.
cat > "$STUB_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_CALLS:-/dev/null}"
exit "${TMUX_STUB_RC:-0}"
EOF

cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
ep=""
for a in "$@"; do case "$a" in /repos/*) ep="$a";; esac; done
method=GET; prev=""
for a in "$@"; do [[ "$prev" == "-X" ]] && method="$a"; prev="$a"; done
case "$method:$ep" in
    POST:*/comments) printf '{}\n' ;;
    POST:*/issues)   printf '{"number":4242}\n' ;;
    GET:*/issues*)   printf '%s\n' "${GH_OPEN_ISSUES_JSON:-[]}" ;;
    *)               printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN"/*
export PATH="$STUB_BIN:$PATH"

MINT_OK="$WORK/mint-ok.sh"
cat > "$MINT_OK" <<'EOF'
#!/usr/bin/env bash
printf 'ghs_faketoken\n'
EOF
chmod +x "$MINT_OK"
# Guard the fixture itself: an empty token makes the escalation fail-soft and
# would silently turn T5/T8 into vacuous passes.
[[ -n "$(bash "$MINT_OK")" ]] || { echo "FATAL: mint stub yields an empty token" >&2; exit 1; }

# A fixture nexus root. NEVER the real tree.
FAKE_ROOT="$WORK/nexus"; mkdir -p "$FAKE_ROOT/monitor/.state"
export NEXUS_MINT_TOKEN_BIN="$MINT_OK"
export MONITOR_REPO="your-org/fixture-nexus"
export MONITOR_USER_LOGIN="fixture-operator"
export MONITOR_OVERVIEW_NUMBER=1

# The guard module calls `log`; main.sh supplies it in production.
log() { printf '[log] %s\n' "$*" >> "${LOG_SINK:-/dev/null}"; }

_snapshot_tree() { find "$1" | sort; }

_reset_incident_state() {
    FS_DEGRADED=0; FS_ONSET=0; FS_LAST_OK=0
    FS_ESCALATED=0; FS_CHANNELS=''; FS_DEGRADED_CYCLES=0
}

# =============================================================================
# T1 — the probe detects a read-only state dir.
#      (Pre-fix: monitor/_fs_probe.sh does not exist.)
# =============================================================================
echo '=== T1: fresh-open probe detects a read-only state dir ==='
assert_file_exists "T1: canonical probe module exists" "$REPO_ROOT/monitor/_fs_probe.sh"

ro="$WORK/ro-state"; mkdir -p "$ro"; chmod 0555 "$ro"
rc=0; nexus_dir_writable "$ro" || rc=$?
assert_eq "T1: read-only dir ⇒ not writable" "$rc" "1"
rc=0; nexus_dir_writable "$WORK" || rc=$?
assert_eq "T1: writable dir ⇒ writable" "$rc" "0"
assert_eq "T1: status word (ro)" "$(nexus_fs_status "$ro")" "READ-ONLY"
assert_eq "T1: status word (rw)" "$(nexus_fs_status "$WORK")" "OK"

# The CLI form, which svc.sh / operators can call directly.
rc=0; bash "$REPO_ROOT/monitor/_fs_probe.sh" -q "$ro" || rc=$?
assert_eq "T1: CLI exits 1 on a read-only dir" "$rc" "1"
rc=0; bash "$REPO_ROOT/monitor/_fs_probe.sh" -q "$WORK" || rc=$?
assert_eq "T1: CLI exits 0 on a writable dir" "$rc" "0"

# =============================================================================
# T2 — THE ONE THAT PINS THE BUG.
#      The probe must use a FRESH open(), not a cached fd. Assert in a single
#      test that a write through a HELD fd still succeeds while the probe
#      reports not-writable. A probe that reuses an fd fails this.
# =============================================================================
echo '=== T2: probe uses a fresh open(), never a held fd ==='
t2="$WORK/t2"; mkdir -p "$t2"
t2_file="$t2/held.log"
: > "$t2_file"

# Open the fd BEFORE the directory becomes read-only — exactly as the
# incumbent watcher held watcher.log open before the remount.
exec {HELD_FD}>>"$t2_file"
chmod 0555 "$t2"

# Fact 1: the held fd keeps working. This is the property that made the
# outage invisible: the running watcher logged normally throughout.
held_ok=0
printf 'written through the held fd\n' >&${HELD_FD} 2>/dev/null && held_ok=1
assert_eq "T2: a write through the HELD fd still succeeds" "$held_ok" "1"
assert_contains "T2: the bytes really landed" "$(cat "$t2_file")" "written through the held fd"

# Fact 2: the probe must nevertheless report NOT writable.
rc=0; nexus_dir_writable "$t2" || rc=$?
assert_eq "T2: the probe reports NOT writable despite the live held fd" "$rc" "1"

exec {HELD_FD}>&-
chmod 0755 "$t2"

# A fresh open() leaves no residue behind on the success path, and each call
# resolves a DISTINCT path (so no call can be served by a previous inode).
nexus_dir_writable "$t2"; nexus_dir_writable "$t2"
leftover=$(find "$t2" -name '.nexus-fs-probe.*' | wc -l)
assert_eq "T2: probe leaves no file behind" "$leftover" "0"
seq_before="${_NEXUS_FS_PROBE_SEQ:-0}"
nexus_dir_writable "$t2"
assert_eq "T2: each probe call takes a new name" \
    "$(( ${_NEXUS_FS_PROBE_SEQ:-0} - seq_before ))" "1"

# =============================================================================
# T3 — svc.sh status surfaces the row and exits non-zero.
#      (Pre-fix: no fs row at all.)
# =============================================================================
echo '=== T3: svc.sh status prints a READ-ONLY fs row and exits non-zero ==='
t3_state="$WORK/t3/monitor/.state"; mkdir -p "$t3_state"; chmod 0555 "$t3_state"
out=$(NEXUS_STATE_DIR="$t3_state" NEXUS_SERVICES_REGISTRY="$WORK/t3/reg" \
      timeout 30 bash "$REPO_ROOT/monitor/svc.sh" status 2>&1); rc=$?
chmod 0755 "$t3_state"
assert_contains "T3: prints an fs row"            "$out" "fs "
assert_contains "T3: row says READ-ONLY"          "$out" "READ-ONLY"
assert_contains "T3: names the remedy"            "$out" "restart the sandbox"
assert_contains "T3: pre-empts a storage-support page"    "$out" "do not page storage-support"
assert_eq       "T3: exits non-zero when READ-ONLY" "$rc" "1"

# The fs row must sit ABOVE the per-service rows: when it is READ-ONLY,
# everything below it is stale.
fs_line=$(printf '%s\n' "$out" | grep -n ' fs  *READ-ONLY' | head -1 | cut -d: -f1)
w_line=$(printf '%s\n' "$out"  | grep -n ' watcher ' | head -1 | cut -d: -f1)
if [[ -n "$fs_line" && -n "$w_line" ]]; then
    [[ "$fs_line" -lt "$w_line" ]] && rc=0 || rc=1
    assert_eq "T3: fs row precedes the service rows" "$rc" "0"
fi

# And a healthy tree must still exit 0 (no false alarm on a fresh clone
# whose monitor/.state has never been created).
t3_ok="$WORK/t3ok/monitor/.state"; mkdir -p "$t3_ok"
out=$(NEXUS_STATE_DIR="$t3_ok" NEXUS_SERVICES_REGISTRY="$WORK/t3ok/reg" \
      timeout 30 bash "$REPO_ROOT/monitor/svc.sh" status 2>&1); rc=$?
assert_contains "T3: healthy tree ⇒ fs OK"  "$out" "OK"
assert_eq       "T3: healthy tree ⇒ exit 0" "$rc" "0"

out=$(NEXUS_STATE_DIR="$WORK/t3fresh/monitor/.state" \
      NEXUS_SERVICES_REGISTRY="$WORK/t3fresh/reg" \
      timeout 30 bash "$REPO_ROOT/monitor/svc.sh" status 2>&1); rc=$?
assert_eq "T3: never-created state dir on a healthy FS ⇒ exit 0" "$rc" "0"

# =============================================================================
# T4 — the escalation writes NOTHING under NEXUS_ROOT.
#      (Pre-fix: _fs_escalate_once does not exist.)
# =============================================================================
echo '=== T4: escalation fires but writes nothing under NEXUS_ROOT ==='
_reset_incident_state
t4_state="$FAKE_ROOT/monitor/.state"; chmod 0555 "$t4_state"
before=$(_snapshot_tree "$FAKE_ROOT")

export NOTIFY_LOG="$WORK/t4-notify.log"; : > "$NOTIFY_LOG"
export GH_CALLS="$WORK/t4-gh.log";       : > "$GH_CALLS"
export TMUX_CALLS="$WORK/t4-tmux.log";   : > "$TMUX_CALLS"
alarm_tmp="$WORK/t4-tmp"; mkdir -p "$alarm_tmp"

STATE_DIR="$t4_state" NEXUS_ROOT="$FAKE_ROOT" TARGET=orchestrator \
    TMPDIR="$alarm_tmp" _fs_escalate_once

after=$(_snapshot_tree "$FAKE_ROOT")
chmod 0755 "$t4_state"

assert_contains "T4: sandbox-notify fired"        "$(cat "$NOTIFY_LOG")" "READ-ONLY"
assert_contains "T4: alarm leads with the remedy" "$(cat "$NOTIFY_LOG")" "RESTART THE SANDBOX"
assert_eq       "T4: NOT ONE file created under NEXUS_ROOT" "$before" "$after"
assert_contains "T4: channels recorded"           "$FS_CHANNELS" "sandbox-notify"

# =============================================================================
# T5 — the escalation reaches GitHub with a warm token cache, still
#      writing nothing under NEXUS_ROOT. (Pre-fix: path does not exist.)
# =============================================================================
echo '=== T5: GitHub escalation on a read-only tree writes nothing locally ==='
_reset_incident_state
chmod 0555 "$t4_state"
before=$(_snapshot_tree "$FAKE_ROOT")
export NOTIFY_LOG="$WORK/t5-notify.log"; : > "$NOTIFY_LOG"
export GH_CALLS="$WORK/t5-gh.log";       : > "$GH_CALLS"
export TMUX_CALLS="$WORK/t5-tmux.log";   : > "$TMUX_CALLS"
alarm_tmp="$WORK/t5-tmp"; mkdir -p "$alarm_tmp"

STATE_DIR="$t4_state" NEXUS_ROOT="$FAKE_ROOT" TARGET=orchestrator \
    TMPDIR="$alarm_tmp" _fs_escalate_once

after=$(_snapshot_tree "$FAKE_ROOT")
chmod 0755 "$t4_state"

assert_contains "T5: an incident issue was POSTed" "$(cat "$GH_CALLS")" "POST"
assert_contains "T5: github channel recorded"      "$FS_CHANNELS" "github-issue"
assert_eq       "T5: still nothing written under NEXUS_ROOT" "$before" "$after"
# The token is minted from $HOME/.claude, never staged in the project tree.
assert_no_file  "T5: no token cache in the project tree" "$FAKE_ROOT/.nexus-bot-token.json"

# The escalation MESSAGE is a deliverable, not an afterthought. Pin its
# contract so it cannot regress into a bare stack trace.
#
# The probe is deliberately errno-agnostic (EROFS / EACCES / ENOSPC all trip
# it), but only ONE of those justifies "the storage is fine, do not page
# storage-support". So the interpretive sentence is gated on the evidence, and BOTH
# branches are pinned here. Asserting the diagnosis unconditionally would be
# the same class of confident falsehood this whole change exists to prevent.

# --- the predicate itself ---
_sig() { _nexus_rofs_signature_matches "$1" "$2" && echo match || echo nomatch; }
assert_eq "T5/sig: rw bind ABSENT ⇒ match"          "$(_sig 'rw,relatime' ABSENT)"  "match"
assert_eq "T5/sig: covering mount ro ⇒ match"       "$(_sig 'ro,relatime' present)" "match"
assert_eq "T5/sig: rw mount + present bind ⇒ none"  "$(_sig 'rw,relatime' present)" "nomatch"
assert_eq "T5/sig: unknown evidence ⇒ nomatch"      "$(_sig '' '')"                 "nomatch"

# --- branch A: evidence MATCHES the detached-bind signature ---
# A project dir with no mount of its own ⇒ rw_bind=ABSENT.
body=$(SANDBOX_PROJECT_DIR="$WORK/no-such-mount" \
       _nexus_incident_issue_body "fixture-operator" "$FAKE_ROOT" "test" "$t4_state" "watcher down")
assert_contains "T5/msgA: leads with the remedy"       "$body" "restarted from OUTSIDE the sandbox"
assert_contains "T5/msgA: pings the operator"          "$body" "@fixture-operator"
assert_contains "T5/msgA: names the mount evidence"    "$body" "superblock"
assert_contains "T5/msgA: says nothing is lost"        "$body" "Nothing is lost or corrupted"
assert_contains "T5/msgA: diagnoses a detached mount"  "$body" "the *storage* is fine"
assert_contains "T5/msgA: says do not page storage-support"    "$body" "do not page storage-support"
assert_contains "T5/msgA: reports free capacity"       "$body" "capacity"
assert_contains "T5/msgA: says what the restart costs" "$body" "ephemeral"
assert_contains "T5/msgA: root cause is NOT claimed"   "$body" "Root cause: NOT established"

# --- branch B: evidence does NOT match (e.g. ENOSPC, or a chmod accident) ---
# `/` is a real, writable mountpoint ⇒ rw_bind=present, covering mount rw.
body=$(SANDBOX_PROJECT_DIR="/" \
       _nexus_incident_issue_body "fixture-operator" "$FAKE_ROOT" "test" "$t4_state" "watcher down")
assert_contains     "T5/msgB: still leads with the remedy" "$body" "restarted from OUTSIDE the sandbox"
assert_contains     "T5/msgB: flags the signature mismatch" "$body" "does not match the known signature"
assert_contains     "T5/msgB: still shows the evidence"    "$body" "capacity"
assert_contains     "T5/msgB: admits a storage problem is possible" "$body" "storage-support should be contacted"
assert_not_contains "T5/msgB: does NOT claim the storage is fine"   "$body" "the *storage* is fine"
assert_not_contains "T5/msgB: does NOT suppress a storage-support page"     "$body" "do not page storage-support"

# --- and neither branch may EVER instruct anyone to circumvent the sandbox ---
for _sbpd in "$WORK/no-such-mount" "/"; do
    body=$(SANDBOX_PROJECT_DIR="$_sbpd" \
           _nexus_incident_issue_body "fixture-operator" "$FAKE_ROOT" "test" "$t4_state" "down")
    assert_contains "T5/msg: forbids remount workarounds" "$body" "Do not attempt to remount"
    for _forbidden in 'unshare -m' 'mount -o remount' 'mount --bind'; do
        assert_not_contains "T5/msg: no '$_forbidden' recipe" "$body" "$_forbidden"
    done
done

# The one-line alarm is gated the same way.
alarm_a=$(SANDBOX_PROJECT_DIR="$WORK/no-such-mount" _nexus_rofs_alarm_text "$t4_state" ctx)
alarm_b=$(SANDBOX_PROJECT_DIR="/" _nexus_rofs_alarm_text "$t4_state" ctx)
assert_contains     "T5/alarmA: suppresses the storage-support page" "$alarm_a" "do not page storage-support"
assert_not_contains "T5/alarmB: does not suppress it"        "$alarm_b" "do not page storage-support"
assert_contains     "T5/alarmB: says to check the evidence"  "$alarm_b" "check free space"
for _a in "$alarm_a" "$alarm_b"; do
    assert_contains "T5/alarm: leads with the remedy" "$_a" "RESTART THE SANDBOX"
    assert_contains "T5/alarm: names the condition"   "$_a" "READ-ONLY"
done

# =============================================================================
# T6 — the PreToolUse hook FAILS OPEN.
#      (Pre-fix: the inline redirect's non-zero status blocked the tool.)
# =============================================================================
echo '=== T6: pending-tool PreToolUse hook fails open on a read-only dir ==='
t6_root="$WORK/t6"; mkdir -p "$t6_root/monitor/.state/pending-tool"
chmod 0555 "$t6_root/monitor/.state/pending-tool"
payload='{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'

rc=0
printf '%s' "$payload" | NEXUS_ROOT="$t6_root" NEXUS_WORKER_WINDOW=w1 \
    bash "$REPO_ROOT/monitor/hooks/pending-tool-record.sh" 2>"$WORK/t6.err" || rc=$?
assert_eq       "T6: hook exits 0 on a read-only pending-tool dir" "$rc" "0"
assert_contains "T6: and says why on stderr" "$(cat "$WORK/t6.err")" "proceeding"

# The PostToolUse clear leg must fail open too.
rc=0
NEXUS_ROOT="$t6_root" NEXUS_WORKER_WINDOW=w1 \
    bash "$REPO_ROOT/monitor/hooks/pending-tool-record.sh" --clear 2>/dev/null || rc=$?
assert_eq "T6: --clear exits 0 on a read-only dir" "$rc" "0"

# CONTROL: the pre-fix inline pipeline this replaced DOES fail here. This is
# what makes T6 a both-directions test rather than a tautology.
rc=0
printf '%s' "$payload" | ( mkdir -p "$t6_root/monitor/.state/pending-tool" \
    && jq -c '{tool:.tool_name}' > "$t6_root/monitor/.state/pending-tool/w1.json" ) \
    2>/dev/null || rc=$?
assert_eq "T6: (control) the pre-fix inline pipeline exits NON-zero" "$rc" "1"

chmod 0755 "$t6_root/monitor/.state/pending-tool"

# On a WRITABLE dir the hook must still do its job.
rc=0
printf '%s' "$payload" | NEXUS_ROOT="$t6_root" NEXUS_WORKER_WINDOW=w1 \
    bash "$REPO_ROOT/monitor/hooks/pending-tool-record.sh" || rc=$?
assert_eq        "T6: writable dir ⇒ exit 0" "$rc" "0"
assert_file_exists "T6: writable dir ⇒ record written" "$t6_root/monitor/.state/pending-tool/w1.json"
assert_contains  "T6: record carries the tool name" \
    "$(cat "$t6_root/monitor/.state/pending-tool/w1.json")" "Bash"
assert_no_file   "T6: no tmp file left behind" "$t6_root/monitor/.state/pending-tool/w1.json.$$.tmp"

# =============================================================================
# T7 — the watcher DEGRADES: its loop survives a read-only STATE_DIR.
#      It must not exit. (Pre-fix: no degraded mode; the successor died in
#      launcher.sh's own log redirect before main.sh ran a single line.)
# =============================================================================
echo '=== T7: the watcher loop survives a read-only STATE_DIR (degrades, no exit) ==='
t7_state="$WORK/t7/monitor/.state"; mkdir -p "$t7_state"
t7_root="$WORK/t7"
harness="$WORK/t7-harness.sh"
cat > "$harness" <<HARNESS
#!/usr/bin/env bash
set -uo pipefail
source "$_dir/_lib.sh"
source "$_dir/_fs_guard.sh"
log() { :; }
STATE_DIR="$t7_state"; NEXUS_ROOT="$t7_root"; TARGET=orchestrator
export MONITOR_ROFS_GITHUB_ESCALATION_ENABLED=false
degraded_cycles=0
for _i in 1 2 3; do
    if ! _fs_guard_tick; then
        degraded_cycles=\$(( degraded_cycles + 1 ))
        continue          # exactly what main.sh's loop does
    fi
done
printf 'DEGRADED_CYCLES=%s FS_DEGRADED=%s\n' "\$degraded_cycles" "\$FS_DEGRADED"
printf 'LOOP-SURVIVED\n'
HARNESS
chmod 0555 "$t7_state"
out=$(NOTIFY_LOG=/dev/null TMPDIR="$WORK/t7-tmp" TMUX_CALLS=/dev/null \
      timeout 30 bash "$harness" 2>&1); rc=$?
mkdir -p "$WORK/t7-tmp" 2>/dev/null
chmod 0755 "$t7_state"

assert_eq       "T7: the loop exits 0 (it did not die)" "$rc" "0"
assert_contains "T7: the loop ran to completion"        "$out" "LOOP-SURVIVED"
assert_contains "T7: every cycle degraded"              "$out" "DEGRADED_CYCLES=3"
assert_contains "T7: it stayed in degraded mode"        "$out" "FS_DEGRADED=1"

# =============================================================================
# T8 — the escalation fires EXACTLY ONCE across N cycles.
#      An alert that repeats every cycle is an alert that gets muted.
# =============================================================================
echo '=== T8: escalation fires exactly once across N degraded cycles ==='
_reset_incident_state
t8_state="$WORK/t8/monitor/.state"; mkdir -p "$t8_state"
t8_root="$WORK/t8"
export NOTIFY_LOG="$WORK/t8-notify.log"; : > "$NOTIFY_LOG"
export GH_CALLS="$WORK/t8-gh.log";       : > "$GH_CALLS"
export TMUX_CALLS="$WORK/t8-tmux.log";   : > "$TMUX_CALLS"
alarm_tmp="$WORK/t8-tmp"; mkdir -p "$alarm_tmp"
chmod 0555 "$t8_state"

n_cycles=5
degraded=0
for _i in $(seq 1 $n_cycles); do
    STATE_DIR="$t8_state" NEXUS_ROOT="$t8_root" TARGET=orchestrator \
        TMPDIR="$alarm_tmp" _fs_guard_tick || degraded=$(( degraded + 1 ))
done
chmod 0755 "$t8_state"

assert_eq "T8: all $n_cycles cycles reported degraded" "$degraded" "$n_cycles"
assert_eq "T8: sandbox-notify rang exactly once"  "$(wc -l < "$NOTIFY_LOG")" "1"
# `-X POST /repos/<r>/issues ` with the trailing space — distinguishes the
# issue-create call from `/issues/<n>/comments`. The stub logs the whole
# multi-line body, so anchor on the call line, not on a line count.
assert_eq "T8: exactly one incident issue POSTed" \
    "$(grep -c -- '-X POST /repos/[^ ]*/issues ' "$GH_CALLS" || true)" "1"
assert_eq "T8: the fire-once latch is set"        "$FS_ESCALATED" "1"
assert_eq "T8: degraded-cycle counter advanced"   "$FS_DEGRADED_CYCLES" "$n_cycles"

# =============================================================================
# T9 — on recovery the watcher leaves a DURABLE trace and re-arms.
#      The 2026-06-29 incident vanished because nothing outlived it.
# =============================================================================
echo '=== T9: recovery writes a durable incident trace and re-arms the alarm ==='
chmod 0755 "$t8_state"
STATE_DIR="$t8_state" NEXUS_ROOT="$t8_root" TARGET=orchestrator \
    TMPDIR="$alarm_tmp" _fs_guard_tick; rc=$?

assert_eq          "T9: the probe reports writable again" "$rc" "0"
assert_eq          "T9: degraded mode cleared"            "$FS_DEGRADED" "0"
assert_eq          "T9: the fire-once latch re-armed"     "$FS_ESCALATED" "0"
assert_file_exists "T9: durable trace written" "$t8_state/fs-incidents.jsonl"
trace=$(cat "$t8_state/fs-incidents.jsonl")
assert_contains "T9: trace names the event"          "$trace" "fs-readonly-incident"
assert_contains "T9: trace records the duration"     "$trace" '"duration_seconds"'
assert_contains "T9: trace records onset bounds"     "$trace" '"onset_before"'
assert_contains "T9: trace records the channel used" "$trace" "sandbox-notify"
assert_eq "T9: exactly one incident recorded" "$(wc -l < "$t8_state/fs-incidents.jsonl")" "1"

# =============================================================================
# T10 — the watcher never self-restarts onto a read-only FS.
#       Both incidents open with version_check -> launcher.sh --replace,
#       which SIGTERMs the one working watcher and cannot start a successor.
# =============================================================================
echo '=== T10: version self-restart is SUPPRESSED on a read-only FS ==='
# shellcheck source=monitor/watcher/_version_restart.sh
source "$_dir/_version_restart.sh"
t10_state="$WORK/t10/version"; mkdir -p "$t10_state"
sentinel="$WORK/t10-launcher-ran"
fake_launcher="$WORK/t10-launcher.sh"
printf '#!/usr/bin/env bash\ntouch %q\n' "$sentinel" > "$fake_launcher"
chmod +x "$fake_launcher"

chmod 0555 "$t10_state"
rc=0
_version_restart_self "$t10_state" "$fake_launcher" orchestrator /dev/null || rc=$?
sleep 0.3   # a forked launcher would have landed the sentinel by now
chmod 0755 "$t10_state"

assert_eq      "T10: self-restart returns non-zero (suppressed)" "$rc" "1"
assert_no_file "T10: the launcher was NEVER forked"              "$sentinel"
assert_no_file "T10: no cooldown stamp written"  "$t10_state/watcher.restart.last"
assert_no_file "T10: no self-restart history written" "$t10_state/self-restart-history.txt"

# CONTROL: on a writable FS the self-restart still happens. Suppression must
# be conditional, not a silent disabling of the whole mechanism.
rc=0
_version_restart_self "$t10_state" "$fake_launcher" orchestrator /dev/null || rc=$?
for _i in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$sentinel" ]] && break; sleep 0.2; done
assert_eq          "T10: (control) writable FS ⇒ self-restart returns 0" "$rc" "0"
assert_file_exists "T10: (control) writable FS ⇒ the launcher DID run"   "$sentinel"

# =============================================================================
# T11/T12 — the LAUNCHER surfaces. This is where both outages actually
#           happened, so they are pinned here rather than left to review.
#           Fixture mirrors test-launcher-replace.sh's faux-watcher pattern.
# =============================================================================
_build_launcher_case() {
    LWORK=$(mktemp -d -t "nexus-fsguard-launcher-XXXXXX")
    mkdir -p "$LWORK/monitor/watcher" "$LWORK/monitor/.state" "$LWORK/bin" "$LWORK/config"
    cp "$_dir/launcher.sh"        "$LWORK/monitor/watcher/launcher.sh"
    cp "$_dir/_lib.sh"            "$LWORK/monitor/watcher/_lib.sh"
    cp "$_dir/_respawn_async.sh"  "$LWORK/monitor/watcher/_respawn_async.sh"
    cp "$REPO_ROOT/monitor/_fs_probe.sh" "$LWORK/monitor/_fs_probe.sh"
    # launcher.sh sources ../_log-mode.sh (nexus-code#509).
    cp "$REPO_ROOT/monitor/_log-mode.sh" "$LWORK/monitor/_log-mode.sh"
    chmod +x "$LWORK/monitor/watcher/launcher.sh"
    LPIDFILE="$LWORK/monitor/.state/watcher.pid"
    # Stub main.sh: publish pid (which FAILS on a read-only .state) then idle.
    # No `exec` — argv must stay `bash .../monitor/watcher/main.sh` for the
    # launcher's identity check.
    cat > "$LWORK/monitor/watcher/main.sh" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$LPIDFILE"
sleep 30
EOF
    chmod +x "$LWORK/monitor/watcher/main.sh"
    printf '#!/usr/bin/env bash\nexit 0\n'        > "$LWORK/bin/tmux"
    printf '#!/usr/bin/env bash\nexit 0\n'        > "$LWORK/bin/sandbox-notify"
    printf '#!/usr/bin/env bash\necho "${2:-}"\n' > "$LWORK/config/load.sh"
    chmod +x "$LWORK/bin/tmux" "$LWORK/bin/sandbox-notify" "$LWORK/config/load.sh"
    # A unit test must never reach the network.
    export MONITOR_ROFS_GITHUB_ESCALATION_ENABLED=false
}
_cleanup_launcher_case() {
    chmod -R u+rwX "$LWORK" 2>/dev/null
    local p=''
    [[ -f "$LPIDFILE" ]] && read -r p < "$LPIDFILE" 2>/dev/null
    [[ "$p" =~ ^[0-9]+$ ]] && th_kill_fixture_pid "$p" "$LWORK"
    [[ -n "${FAUX_PID:-}" ]] && th_kill_fixture_pid "$FAUX_PID" "$LWORK"
    rm -rf "$LWORK"
    unset LWORK LPIDFILE FAUX_PID
}

echo '=== T11: launcher --replace REFUSES on a read-only FS (no decapitation) ==='
_build_launcher_case
mkdir -p "$LWORK/faux/monitor/watcher"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$LWORK/faux/monitor/watcher/main.sh"
chmod +x "$LWORK/faux/monitor/watcher/main.sh"
bash "$LWORK/faux/monitor/watcher/main.sh" & FAUX_PID=$!
sleep 0.3     # let the kernel commit the cmdline
echo "$FAUX_PID" > "$LPIDFILE"
chmod 0555 "$LWORK/monitor/.state"

t11_tmp="$WORK/t11-tmp"; mkdir -p "$t11_tmp"
rc=0
PATH="$LWORK/bin:$PATH" TMPDIR="$t11_tmp" \
    timeout 60 bash "$LWORK/monitor/watcher/launcher.sh" --replace --target orchestrator \
    >"$LWORK/out" 2>"$LWORK/err" || rc=$?
chmod 0755 "$LWORK/monitor/.state"

assert_eq       "T11: --replace exits 5 (refused)"                  "$rc" "5"
assert_contains "T11: says REFUSED"                                 "$(cat "$LWORK/err")" "REFUSED"
assert_contains "T11: names READ-ONLY"                              "$(cat "$LWORK/err")" "READ-ONLY"
assert_contains "T11: tells the operator to restart from OUTSIDE"   "$(cat "$LWORK/err")" "OUTSIDE"
# THE POINT: the working incumbent must still be alive.
if kill -0 "$FAUX_PID" 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "T11: the incumbent watcher is STILL ALIVE (not decapitated)" "$rc" "0"
_cleanup_launcher_case

echo '=== T12: launcher cold-start on a read-only FS starts DEGRADED, does not die ==='
_build_launcher_case
chmod 0555 "$LWORK/monitor/.state"     # no incumbent; no pidfile is possible
t12_tmp="$WORK/t12-tmp"; mkdir -p "$t12_tmp"

rc=0
PATH="$LWORK/bin:$PATH" TMPDIR="$t12_tmp" \
    timeout 90 bash "$LWORK/monitor/watcher/launcher.sh" --target orchestrator \
    >"$LWORK/out" 2>"$LWORK/err" || rc=$?
chmod 0755 "$LWORK/monitor/.state"

assert_eq       "T12: cold start exits 0 (degraded, not failed)" "$rc" "0"
assert_contains "T12: reports degraded mode"                     "$(cat "$LWORK/err")" "DEGRADED"
assert_contains "T12: explains the pidfile is impossible"        "$(cat "$LWORK/err")" "no pidfile is possible"
# The successor must NOT have died in its own log redirect: the log is
# relocated to a writable mount, so main.sh actually got to run.
assert_file_exists "T12: log fell back to a writable mount" "$t12_tmp/nexus-watcher-degraded.log"
assert_no_file     "T12: nothing was written into the read-only state dir" "$LPIDFILE"
_cleanup_launcher_case

th_summary_and_exit
