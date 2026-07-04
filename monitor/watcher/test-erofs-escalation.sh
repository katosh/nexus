#!/usr/bin/env bash
# Tests for the read-only-filesystem escalation path
# (your-org/nexus-code rofs-incident).
#
# Incident: an NFS-server flap dropped the project's writable bind from
# the tmux-server's MS_SLAVE mount namespace, so monitor/.state went
# read-only. The watcher died on EROFS and EVERY revive/restart silently
# retry-failed for ~25 min with NO operator alarm — the contract
# ("a watcher crash always has turn-independent revival") was violated
# with no escalation. These tests cover the hardening:
#   * _nexus_dir_writable     — ground-truth state-dir writability probe
#   * _nexus_critical_alarm   — throttled, project-FS-INDEPENDENT operator
#                               alarm (rings sandbox-notify + stderr)
#   * revive-watcher.sh       — read-only state dir ⇒ exit 4, NO futile
#                               svc.sh restart, alarm fired
#   * watcher-supervise-tick  — read-only state dir ⇒ alarm fired, still
#                               reports DOWN (orchestrator still woken)
#
# A 0555 directory is a hermetic stand-in for a read-only mount: the
# write-probe is errno-agnostic (EACCES from the mode bits is treated
# exactly like EROFS from a RO mount), so it exercises the same code
# path without needing a real read-only filesystem.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_lib.sh
source "$_dir/_lib.sh"
REVIVE="$_dir/../revive-watcher.sh"
SUPERVISE="$_dir/../watcher-supervise-tick.sh"

WORK=$(mktemp -d)
# 0555 fixtures must be made writable again before rm can recurse them.
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# A sandbox-notify stub that records each call to $NOTIFY_LOG, placed
# first on PATH. Writing to a WRITABLE recorder (never the read-only
# state dir) also demonstrates the alarm path does not depend on the
# project FS.
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/sandbox-notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NOTIFY_LOG:?NOTIFY_LOG required}"
exit 0
EOF
chmod +x "$STUB_BIN/sandbox-notify"

# A `gh` stub for the GitHub-escalation path. Records every invocation to
# $GH_CALLS (default /dev/null so unrelated callers never trip on an unset
# var) and synthesizes API responses by method+endpoint so the escalation
# never touches the real network. Placed first on PATH, it ALSO shadows
# the real gh for the revive/supervise integration tests below — combined
# with MONITOR_ROFS_GITHUB_ESCALATION_ENABLED=false there, no real mint/gh
# call ever fires from a unit test.
cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
log="${GH_CALLS:-/dev/null}"
printf '%s\n' "$*" >> "$log"
ep=""
for a in "$@"; do case "$a" in /repos/*) ep="$a";; esac; done
method=GET; prev=""
for a in "$@"; do [[ "$prev" == "-X" ]] && method="$a"; prev="$a"; done
case "$ep" in
    *labels=nexus:overview*) printf '[{"number":1}]\n' ;;
    *)
        case "$method:$ep" in
            POST:*/comments) printf '{}\n' ;;
            POST:*/issues)   printf '{"number":4242}\n' ;;
            GET:*/issues*)
                # Honor pagination: page>=2 returns GH_OPEN_ISSUES_JSON_P2
                # (default empty), page 1 (or unspecified) returns the
                # primary fixture. Anchor on the LITERAL "&page=" so the
                # "page=1" substring inside "per_page=100" never matches.
                case "$ep" in
                    *'&page=1') printf '%s\n' "${GH_OPEN_ISSUES_JSON:-[]}" ;;
                    *'&page='*) printf '%s\n' "${GH_OPEN_ISSUES_JSON_P2:-[]}" ;;
                    *)          printf '%s\n' "${GH_OPEN_ISSUES_JSON:-[]}" ;;
                esac ;;
            *)               printf '{}\n' ;;
        esac ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# mint-token stubs: one that prints a fake token (success), one that
# fails (fail-soft). Pointed at via NEXUS_MINT_TOKEN_BIN so no real App
# credential / network mint is exercised.
MINT_OK="$WORK/mint-ok.sh"
cat > "$MINT_OK" <<'EOF'
#!/usr/bin/env bash
printf 'ghs_faketoken_for_tests\n'
EOF
chmod +x "$MINT_OK"
MINT_FAIL="$WORK/mint-fail.sh"
cat > "$MINT_FAIL" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$MINT_FAIL"

# The nexus clone root (has a real config/load.sh) — the escalation reads
# config from here when an env override is absent.
ESC_ROOT=$(cd "$_dir/../.." && pwd)

# Skip the read-only assertions when running as root (mode bits are
# ignored by root, so a 0555 dir is still writable for it).
_can_test_ro=1
[[ "$(id -u)" == "0" ]] && _can_test_ro=0

# === _nexus_dir_writable ====================================================
rc=0; _nexus_dir_writable "$WORK" || rc=$?
assert_eq "dir_writable: writable dir ⇒ rc 0" "$rc" "0"

rc=0; _nexus_dir_writable "$WORK/does-not-exist" || rc=$?
assert_eq "dir_writable: missing dir ⇒ rc 1" "$rc" "1"

if (( _can_test_ro )); then
    ro_dir="$WORK/ro"
    mkdir -p "$ro_dir"; chmod 0555 "$ro_dir"
    if ! ( : > "$ro_dir/.probe" ) 2>/dev/null; then
        rc=0; _nexus_dir_writable "$ro_dir" || rc=$?
        assert_eq "dir_writable: read-only dir ⇒ rc 1" "$rc" "1"
    fi
    chmod 0755 "$ro_dir"
fi

# === _nexus_critical_alarm: fires once, then throttles ======================
alarm_tmp="$WORK/alarm-tmp"; mkdir -p "$alarm_tmp"
NOTIFY_LOG="$WORK/notify-1.log"; : > "$NOTIFY_LOG"
rc=0; TMPDIR="$alarm_tmp" NOTIFY_LOG="$NOTIFY_LOG" \
    _nexus_critical_alarm "unit-key" 120 "read-only test message" || rc=$?
assert_eq        "alarm: first call rings ⇒ rc 0"      "$rc" "0"
assert_contains  "alarm: sandbox-notify got the msg"   "$(cat "$NOTIFY_LOG")" "read-only test message"
assert_contains  "alarm: rings as CRITICAL"            "$(cat "$NOTIFY_LOG")" "CRITICAL"
# Throttle marker lands in TMPDIR (writable when the project FS is not),
# NOT in the project state dir.
assert_file_exists "alarm: throttle marker in TMPDIR" "$alarm_tmp/.nexus-critical-alarm.unit-key"

rings_before=$(wc -l < "$NOTIFY_LOG")
rc=0; TMPDIR="$alarm_tmp" NOTIFY_LOG="$NOTIFY_LOG" \
    _nexus_critical_alarm "unit-key" 120 "read-only test message" || rc=$?
assert_eq "alarm: second call within window ⇒ rc 1 (throttled)" "$rc" "1"
rings_after=$(wc -l < "$NOTIFY_LOG")
assert_eq "alarm: throttled call does NOT ring again" "$rings_after" "$rings_before"

# A different key is independent (not throttled by the first).
rc=0; TMPDIR="$alarm_tmp" NOTIFY_LOG="$NOTIFY_LOG" \
    _nexus_critical_alarm "other-key" 120 "second condition" || rc=$?
assert_eq "alarm: distinct key rings ⇒ rc 0" "$rc" "0"

# === revive-watcher.sh: read-only state dir ⇒ exit 4, no futile restart =====
if (( _can_test_ro )); then
    rv_state="$WORK/rv-state"; mkdir -p "$rv_state"
    # A heartbeat with an OLD mtime ⇒ _watcher_alive reports DOWN, so revive
    # proceeds past its already-alive short-circuit and reaches the RO guard.
    : > "$rv_state/watcher-heartbeat"
    touch -d '2000-01-01 00:00:00' "$rv_state/watcher-heartbeat" 2>/dev/null \
        || touch -t 200001010000 "$rv_state/watcher-heartbeat"
    # svc stub that MUST NOT be invoked (we must short-circuit before it).
    svc_called="$WORK/svc-was-called"
    svc_stub="$WORK/svc-stub.sh"
    cat > "$svc_stub" <<EOF
#!/usr/bin/env bash
printf 'called %s\n' "\$*" >> "$svc_called"
exit 0
EOF
    chmod +x "$svc_stub"

    chmod 0555 "$rv_state"
    if ! ( : > "$rv_state/.probe" ) 2>/dev/null; then
        rv_tmp="$WORK/rv-tmp"; mkdir -p "$rv_tmp"
        rv_notify="$WORK/notify-revive.log"; : > "$rv_notify"
        rc=0
        out=$(NEXUS_STATE_DIR="$rv_state" REVIVE_SVC_BIN="$svc_stub" \
              TMPDIR="$rv_tmp" NOTIFY_LOG="$rv_notify" \
              MONITOR_ROFS_GITHUB_ESCALATION_ENABLED=false \
              bash "$REVIVE" 2>&1) || rc=$?
        assert_eq        "revive: read-only state dir ⇒ exit 4"   "$rc" "4"
        assert_no_file   "revive: svc.sh restart NOT invoked"     "$svc_called"
        assert_contains  "revive: alarm rang sandbox-notify"      "$(cat "$rv_notify")" "READ-ONLY"
        assert_contains  "revive: log names the read-only cause"  "$out" "READ-ONLY"
    fi
    chmod 0755 "$rv_state"
fi

# === watcher-supervise-tick.sh: read-only ⇒ alarm + still reports DOWN ======
if (( _can_test_ro )); then
    sv_state="$WORK/sv-state"; mkdir -p "$sv_state"
    : > "$sv_state/watcher-heartbeat"
    touch -d '2000-01-01 00:00:00' "$sv_state/watcher-heartbeat" 2>/dev/null \
        || touch -t 200001010000 "$sv_state/watcher-heartbeat"
    chmod 0555 "$sv_state"
    if ! ( : > "$sv_state/.probe" ) 2>/dev/null; then
        sv_tmp="$WORK/sv-tmp"; mkdir -p "$sv_tmp"
        sv_notify="$WORK/notify-supervise.log"; : > "$sv_notify"
        rc=0
        out=$(NEXUS_STATE_DIR="$sv_state" TMPDIR="$sv_tmp" NOTIFY_LOG="$sv_notify" \
              MONITOR_ROFS_GITHUB_ESCALATION_ENABLED=false \
              bash "$SUPERVISE" 2>&1) || rc=$?
        # Still DOWN (non-zero) so `until ! tick` exits and wakes the orchestrator.
        assert_eq       "supervise: read-only + dead watcher ⇒ non-zero (DOWN)" "$rc" "1"
        assert_contains "supervise: alarm rang sandbox-notify"  "$(cat "$sv_notify")" "READ-ONLY"
    fi
    chmod 0755 "$sv_state"
fi

# === _nexus_github_incident_escalate: GitHub + overview escalation ==========
# The #377 ask: the EROFS alarm must ALSO escalate to a GitHub issue and the
# nexus overview with an operator ping. RO-FS-safe (network-only via the BOT
# token + a direct `gh api`; no `ng`, no project-FS write, no local marker),
# idempotent over the network (one issue per outage), fail-soft.

esc_state="$WORK/esc-state"; mkdir -p "$esc_state"

# --- create path: no open incident ⇒ file issue + ping overview ----------
GH_CALLS="$WORK/gh-calls-create.log"; : > "$GH_CALLS"
rc=0
GH_CALLS="$GH_CALLS" GH_OPEN_ISSUES_JSON='[]' \
    MONITOR_REPO="your-org/your-nexus" MONITOR_USER_LOGIN="operator" \
    MONITOR_ROFS_GITHUB_ESCALATION_ENABLED=true NEXUS_MINT_TOKEN_BIN="$MINT_OK" \
    _nexus_github_incident_escalate "$ESC_ROOT" "$esc_state" "test-context" \
        "heartbeat stale (age=999s)" || rc=$?
calls=$(cat "$GH_CALLS")
assert_eq       "escalate: create path ⇒ rc 0"                 "$rc" "0"
assert_contains "escalate: POSTs a direct incident issue"     "$calls" "POST /repos/your-org/your-nexus/issues"
assert_contains "escalate: incident body @-pings the operator" "$calls" "@operator"
assert_contains "escalate: comments on the overview issue"    "$calls" "/issues/1/comments"
assert_contains "escalate: overview comment links the incident" "$calls" "#4242"
# Never routed through an `ng` verb (those write the read-only state dir).
assert_not_contains "escalate: does NOT shell out to ng"      "$calls" "report-init"
# Operator-friendly body (#377 comment 4837922865): plain-language lead +
# step-by-step recovery runbook with the exact restart command and the
# inner-vs-outer tmux disambiguation.
assert_contains "escalate: body leads with a plain-language explanation" "$calls" "no technical knowledge required"
assert_contains "escalate: body gives the exact restart command"   "$calls" "agent-sandbox tmux new-session ./watcher --continue"
assert_contains "escalate: body warns against the OUTER tmux prefix" "$calls" "outer"

# --- RO-FS safety: succeeds against a read-only state dir, writes nothing --
if (( _can_test_ro )); then
    ro_state="$WORK/esc-ro-state"; mkdir -p "$ro_state"; chmod 0555 "$ro_state"
    if ! ( : > "$ro_state/.probe" ) 2>/dev/null; then
        GH_CALLS="$WORK/gh-calls-ro.log"; : > "$GH_CALLS"
        rc=0
        GH_CALLS="$GH_CALLS" GH_OPEN_ISSUES_JSON='[]' \
            MONITOR_REPO="your-org/your-nexus" MONITOR_USER_LOGIN="operator" \
            MONITOR_OVERVIEW_NUMBER=1 MONITOR_ROFS_GITHUB_ESCALATION_ENABLED=true \
            NEXUS_MINT_TOKEN_BIN="$MINT_OK" \
            _nexus_github_incident_escalate "$ESC_ROOT" "$ro_state" "ro-test" "down" || rc=$?
        assert_eq "escalate: READ-ONLY state dir ⇒ still rc 0 (network-only)" "$rc" "0"
        leaked=$(find "$ro_state" -mindepth 1 2>/dev/null | head -1)
        assert_eq "escalate: writes NOTHING to the read-only state dir"       "$leaked" ""
    fi
    chmod 0755 "$ro_state"
fi

# --- idempotency: an incident issue is already open ⇒ NO duplicate --------
GH_CALLS="$WORK/gh-calls-dup.log"; : > "$GH_CALLS"
rc=0
GH_CALLS="$GH_CALLS" \
    GH_OPEN_ISSUES_JSON='[{"number":77,"title":"cc-incident: watcher down (read-only project FS)"}]' \
    MONITOR_REPO="your-org/your-nexus" MONITOR_USER_LOGIN="operator" \
    MONITOR_OVERVIEW_NUMBER=1 MONITOR_ROFS_GITHUB_ESCALATION_ENABLED=true \
    NEXUS_MINT_TOKEN_BIN="$MINT_OK" \
    _nexus_github_incident_escalate "$ESC_ROOT" "$esc_state" "test" "down" || rc=$?
calls_dup=$(cat "$GH_CALLS")
assert_eq           "escalate: existing open incident ⇒ rc 0 (idempotent)" "$rc" "0"
assert_not_contains "escalate: existing incident ⇒ creates NO issue/comment" "$calls_dup" "POST"

# --- pagination: incident hidden past page 1 (>100 open issues) -----------
# Page 1 is full (100 unrelated issues) so the dedup must fetch page 2,
# where the existing incident lives — and then NOT file a duplicate.
GH_CALLS="$WORK/gh-calls-paginate.log"; : > "$GH_CALLS"
page1_full=$(jq -nc '[range(100) | {number:(.+1), title:"unrelated issue"}]')
rc=0
GH_CALLS="$GH_CALLS" GH_OPEN_ISSUES_JSON="$page1_full" \
    GH_OPEN_ISSUES_JSON_P2='[{"number":88,"title":"cc-incident: watcher down (read-only project FS)"}]' \
    MONITOR_REPO="your-org/your-nexus" MONITOR_USER_LOGIN="operator" \
    MONITOR_OVERVIEW_NUMBER=1 MONITOR_ROFS_GITHUB_ESCALATION_ENABLED=true \
    NEXUS_MINT_TOKEN_BIN="$MINT_OK" \
    _nexus_github_incident_escalate "$ESC_ROOT" "$esc_state" "test" "down" || rc=$?
calls_pg=$(cat "$GH_CALLS")
assert_eq           "escalate: paginates dedup past 100 open issues ⇒ rc 0" "$rc" "0"
assert_contains     "escalate: fetched page 2 of open issues"          "$calls_pg" "page=2"
assert_not_contains "escalate: incident found on page 2 ⇒ NO duplicate" "$calls_pg" "POST"

# --- fail-soft: mint failure ⇒ non-zero, no gh calls ----------------------
GH_CALLS="$WORK/gh-calls-mintfail.log"; : > "$GH_CALLS"
rc=0
GH_CALLS="$GH_CALLS" \
    MONITOR_REPO="your-org/your-nexus" MONITOR_USER_LOGIN="operator" \
    MONITOR_OVERVIEW_NUMBER=1 MONITOR_ROFS_GITHUB_ESCALATION_ENABLED=true \
    NEXUS_MINT_TOKEN_BIN="$MINT_FAIL" \
    _nexus_github_incident_escalate "$ESC_ROOT" "$esc_state" "test" "down" || rc=$?
assert_eq "escalate: mint failure ⇒ rc 1 (fail-soft)"  "$rc" "1"
assert_eq "escalate: mint failure ⇒ no gh API calls"   "$(cat "$WORK/gh-calls-mintfail.log")" ""

# --- config gate: disabled ⇒ rc 2, no work --------------------------------
GH_CALLS="$WORK/gh-calls-disabled.log"; : > "$GH_CALLS"
rc=0
GH_CALLS="$GH_CALLS" \
    MONITOR_REPO="your-org/your-nexus" MONITOR_USER_LOGIN="operator" \
    MONITOR_ROFS_GITHUB_ESCALATION_ENABLED=false NEXUS_MINT_TOKEN_BIN="$MINT_OK" \
    _nexus_github_incident_escalate "$ESC_ROOT" "$esc_state" "test" "down" || rc=$?
assert_eq "escalate: disabled by config ⇒ rc 2"        "$rc" "2"
assert_eq "escalate: disabled ⇒ no gh API calls"       "$(cat "$WORK/gh-calls-disabled.log")" ""

th_summary_and_exit
