#!/usr/bin/env bash
# Tests for monitor/remote-forced-command.sh — the SSH forced-command
# dispatcher that is the load-bearing confinement of the remote agent
# channel (agent-channel RFC Part A §4.2 / §D.2 / §D.4).
#
# This is the security crux: the single point where a remote string
# becomes an action. The suite hammers the confinement hardest —
#   1.  request file → id printed; origin FORCED to remote-<principal>
#   2.  SSH_ORIGINAL_COMMAND injection (;  &&  $(…)  `…`  newline) is inert
#   3.  --origin / --principal / --file / '-' smuggling REFUSED (rc12)
#   4.  unknown verb / unknown request sub → fail closed (rc12), never a shell
#   5.  service disabled → refuse (rc10); missing/invalid principal → (rc11)
#   6.  await: forces --principal; ownership-scoped (cross-principal rc5);
#       traversal id refused; --interval/--principal smuggling refused
#   7.  fetch: selector enum enforced; traversal id refused; extra arg refused
#   8.  attach: disabled by default (rc13); when enabled, PINNED to
#       `tmux attach -t nexus -r` with NO client args forwarded (un-wideable)
#  10.  EVERY refusal arm fires, asserted by its OWN message — 38 of the 43
#       arms share rc12, so an rc-only assertion cannot say which one ran
#  11.  RATCHET (your-org/nexus-code#1279): the set of `refuse` arms in the
#       wrapper must equal the manifest, and every arm declared `covered`
#       must appear in this run's audit log. Adding a guard to the
#       confinement boundary without testing it is now a RED, not an
#       out-of-band audit finding.
#
# Hermetic: drives the REAL Phase-1 inbox (request-channel.sh via ng) under
# a fixture NEXUS_STATE_DIR; tmux is a PATH-shadow stub recording argv. No
# network, no sshd, no real tmux.
#
# Run: bash monitor/watcher/test-remote-forced-command.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
FC="$MON_DIR/remote-forced-command.sh"
RC="$MON_DIR/request-channel.sh"

assert_rc() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — rc %s want %s\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}

WORK=$(mktemp -d -t nexus-remote-fc-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_STATE_DIR="$WORK/state"
export MONITOR_REMOTE_PRINCIPALS_DIR="$WORK/principals"
export NEXUS_REMOTE_LOG="$WORK/fc.log"

# ── HERMETIC CONFIG + AN SSH PEER (your-org/nexus-code#609 finding F12) ─────
# Two independent leaks, both of which made this suite's verdict depend on the
# machine it ran on. It is the THIRD suite in this family with the same defect; the
# other two were fixed in `983a601` and this one needed both remedies and got
# neither.
#
# 1. CONFIG. `config/load.sh` resolves its root from $NEXUS_ROOT, which EVERY nexus
#    agent has set — so a run from any clone read the PRIMARY clone's
#    config/nexus.yml, i.e. this operator's live `from_cidr`. Pin NEXUS_CONFIG at a
#    fixture instead. Note an empty env override does NOT neutralize a configured
#    value: `_remote_cfg` treats "" as unset (`[[ -n "$val" ]]`), so
#    MONITOR_REMOTE_FROM_CIDR="" cannot opt out of an operator's pin — a fixture
#    config file is the only reliable isolation.
# 2. SSH_CLIENT. The wrapper is ONLY ever invoked as an sshd forced command, and
#    sshd always sets SSH_CLIENT. Omitting it modelled an invocation that cannot
#    occur in production, so gate 3 correctly fails closed on an undeterminable peer
#    and 74 cases got exit 14 where they assert 12/0.
#
# Measured before the fix, at `065bd99`: NEXUS_ROOT set -> 17 passed / 74 failed;
# `env -u NEXUS_ROOT` -> 91/0. CI was green only because a CI checkout has no
# config/nexus.yml and the documented full-suite drive unsets NEXUS_ROOT. A suite
# whose verdict flips on an ambient variable is not testing the code.
cat >"$WORK/nexus.yml" <<'FCYML'
monitor:
  remote:
    bind_address: 127.0.0.1
    from_cidr: ""
FCYML
export NEXUS_CONFIG="$WORK/nexus.yml"
# Present as sshd would present it, so gate 3 is exercised rather than tripped.
# The fail-closed-on-unknown-peer behaviour itself is asserted directly in
# test-remote-source-enforcement.sh, so nothing is lost by supplying it here.
export SSH_CLIENT="140.107.116.184 51234 22022"
# Registration IS the enable signal (no MONITOR_REMOTE_ENABLED flag): the
# wrapper gates on the nexus-remote-ssh row in services.registry. Register it.
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
printf 'nexus-remote-ssh\t%s\tlaunch\thealth\tlog\temit-only\n' "$WORK" > "$NEXUS_SERVICES_REGISTRY"
mkdir -p "$NEXUS_STATE_DIR"
REQ="$NEXUS_STATE_DIR/requests"

# tmux stub: record argv, exit 0 (so the `attach` exec is observable).
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$WORK/tmux-argv"
exit 0
EOF
chmod +x "$STUB/tmux"

# run the forced command for <principal> with a given SSH_ORIGINAL_COMMAND.
# Usage: fc <principal> <command-string> [<stdin>]
fc() {
    local principal="$1" cmd="$2" input="${3-}"
    if [[ -n "$input" ]]; then
        SSH_ORIGINAL_COMMAND="$cmd" PATH="$STUB:$PATH" bash "$FC" "$principal" <<<"$input"
    else
        SSH_ORIGINAL_COMMAND="$cmd" PATH="$STUB:$PATH" bash "$FC" "$principal" </dev/null
    fi
}
_claim() { local id="$1"; mv "$REQ/$id.new.md" "$REQ/$id.claimed.md"; }

echo "== 1. request file: id printed; origin FORCED remote-<principal> =="
id=$(fc alice 'request file --kind question --reply required --slug summarize-foo --message Summarize work foo please')
assert_rc "file rc0" "$?" "0"
assert_file_exists "request .new.md written" "$REQ/$id.new.md"
body=$("$RC" show "$id")
assert_contains "origin forced to remote-alice" "$body" "origin: remote-alice"
assert_contains "kind passed through"           "$body" "kind: question"
assert_contains "reply required passed"          "$body" "reply: required"
assert_contains "message body present"           "$body" "Summarize work foo please"

echo "== 1b. --message-stdin captures the piped body (regression: not literal '-') =="
# The bug: the stdin branch exec'd `ng request file … --message -`, and
# request file's `--message` treats the NEXT token as LITERAL text — so the
# body persisted as the one-char "-" and stdin was NEVER read. Live evidence:
# 3 of 4 --message-stdin requests landed with an empty "-" body while the one
# inline request came through. The fix passes a BARE `-` sentinel so the body
# is read from stdin verbatim.
sid=$(fc alice 'request file --kind report --slug stdin-body --message-stdin' \
        'multi-line body
with a second line')
assert_rc "message-stdin file rc0" "$?" "0"
sbody=$("$RC" show "$sid")
assert_contains "stdin body line 1 captured" "$sbody" "multi-line body"
assert_contains "stdin body line 2 captured" "$sbody" "with a second line"
# The buggy path persisted the whole body as the one-char sentinel "-".
# Extract the ## Details section verbatim and assert it is the piped text,
# not "-".
sdetails=$(printf '%s\n' "$sbody" | awk '/^## Details/{p=1;next} p&&NF{print}')
assert_eq "## Details body is the piped text, not the '-' sentinel" \
    "$sdetails" $'multi-line body\nwith a second line'

echo "== 1c. ISSUE C: --reply optional|none accepted as a no-op (within the allowed 'request file') =="
oid=$(fc alice 'request file --kind question --reply optional --slug reply-opt --message please'); assert_rc "--reply optional → rc0" "$?" "0"
assert_file_exists "reply-optional request written" "$REQ/$oid.new.md"
obody=$("$RC" show "$oid")
# optional==default (not required): NO reply: frontmatter line is emitted.
grep -q '^reply:' <<<"$obody" && assert_rc "no reply: frontmatter for --reply optional" 1 0 \
                              || assert_rc "no reply: frontmatter for --reply optional" 0 0
nid2=$(fc alice 'request file --kind question --reply none --slug reply-none --message please'); assert_rc "--reply none → rc0" "$?" "0"
# a bogus --reply value is still fail-closed (rc12).
fc alice 'request file --reply maybe --slug reply-bad --message please' >/dev/null 2>&1
assert_rc "--reply maybe (bogus) refused rc12" "$?" "12"

echo "== 1d. bounded stdin body: REMOTE_BODY_MAX_BYTES ceiling (#483 Part 2) =="
# Oversize body → refused rc12 BEFORE any request file exists (closes the
# authenticated-client disk-fill hole: stdin used to stream unbounded into
# the inbox).
pre_count=$(find "$REQ" -maxdepth 1 -name '*.new.md' 2>/dev/null | wc -l)
REMOTE_BODY_MAX_BYTES=64 fc alice 'request file --kind report --slug too-big --message-stdin' \
    "$(head -c 200 /dev/zero | tr '\0' 'x')" >/dev/null 2>&1
assert_rc "oversize stdin body refused rc12" "$?" "12"
post_count=$(find "$REQ" -maxdepth 1 -name '*.new.md' 2>/dev/null | wc -l)
assert_eq "no request file created for a refused oversize body" "$post_count" "$pre_count"
# Under the ceiling → accepted (the fc harness herestring adds 1 newline).
okid=$(REMOTE_BODY_MAX_BYTES=64 fc alice 'request file --kind report --slug at-cap --message-stdin' \
    "$(head -c 40 /dev/zero | tr '\0' 'y')")
assert_rc "under-ceiling stdin body accepted rc0" "$?" "0"
assert_file_exists "under-ceiling request written" "$REQ/$okid.new.md"
# No staged .body.* temp lingers in the principals dir (unlink-after-open;
# EXIT trap covers the refuse path).
lingering=$(find "$MONITOR_REMOTE_PRINCIPALS_DIR" -maxdepth 1 -name '.body.*' 2>/dev/null | wc -l)
assert_eq "no staged body temp lingers in the principals dir" "$lingering" "0"

echo "== 1e. --checksum echoes sha256+bytes of the RECEIVED body before the id =="
payload='verify me byte-exact'
# The fc harness delivers the payload via a herestring, which appends one
# newline — the checksum covers the bytes RECEIVED, so expect payload+\n.
want_sha=$(printf '%s\n' "$payload" | sha256sum | awk '{print $1}')
want_bytes=$(printf '%s\n' "$payload" | wc -c)
out=$(fc alice 'request file --kind report --slug checked --checksum --message-stdin' "$payload")
assert_rc "checksum file rc0" "$?" "0"
first_line=$(printf '%s\n' "$out" | head -1)
assert_eq "first output line is the received-body checksum" \
    "$first_line" "sha256=$want_sha bytes=$want_bytes"
cid=$(printf '%s\n' "$out" | tail -1)
assert_file_exists "checksummed request written (id on last line)" "$REQ/$cid.new.md"
cbody=$("$RC" show "$cid")
assert_contains "checksummed body captured verbatim" "$cbody" "$payload"
# --checksum with an inline --message is refused (argv is whitespace-joined;
# there is no byte-exact client-side reference to verify against).
fc alice 'request file --slug bad-ck --checksum --message hello there' >/dev/null 2>&1
assert_rc "--checksum with inline --message refused rc12" "$?" "12"

echo "== 2. SSH_ORIGINAL_COMMAND injection is inert =="
# (a) metachars in a message are literal text, never executed.
rm -f "$WORK/SENTINEL"
fc alice 'request file --slug inj --message hi; touch '"$WORK"'/SENTINEL' >/dev/null
assert_no_file "shell ';' in message did not execute" "$WORK/SENTINEL"
# (b) command substitution as an await id → illegal id, nothing runs.
rm -f "$WORK/SENTINEL"
fc alice 'request await $(touch '"$WORK"'/SENTINEL)' >/dev/null 2>&1
assert_rc "command-subst id refused rc12" "$?" "12"
assert_no_file "command substitution never executed" "$WORK/SENTINEL"
# (c) newline in the command → refuse 12 (argument smuggling).
fc alice $'request file --slug x --message hi\nrequest await evil' >/dev/null 2>&1
assert_rc "newline in command refused rc12" "$?" "12"
# (d) backtick is an inert literal token.
rm -f "$WORK/SENTINEL"
fc alice 'request await `touch '"$WORK"'/SENTINEL`' >/dev/null 2>&1
assert_no_file "backtick never executed" "$WORK/SENTINEL"

echo "== 3. spoof / passthrough flags refused (rc12) =="
fc alice 'request file --origin remote-bob --slug x --message hi' >/dev/null 2>&1
assert_rc "--origin spoof refused" "$?" "12"
fc alice 'request file --principal remote-bob --slug x --message hi' >/dev/null 2>&1
assert_rc "--principal refused"     "$?" "12"
fc alice 'request file --file /etc/passwd --slug x' >/dev/null 2>&1
assert_rc "--file (server path) refused" "$?" "12"
fc alice 'request file --slug x -' >/dev/null 2>&1
assert_rc "stdin sentinel '-' refused" "$?" "12"
# a bare '-' as the inline message body is ambiguous (would read stdin / hang)
fc alice 'request file --slug x --message -' >/dev/null 2>&1
assert_rc "ambiguous '-' inline body refused" "$?" "12"

echo "== 4. unknown verbs fail closed (rc12), never a shell =="
fc alice 'cat /etc/passwd' >/dev/null 2>&1
assert_rc "unknown verb refused" "$?" "12"
fc alice 'request reply someid --message pwn' >/dev/null 2>&1
assert_rc "orchestrator-only 'reply' not exposed" "$?" "12"
fc alice 'request list' >/dev/null 2>&1
assert_rc "non-scoped 'list' not exposed" "$?" "12"
# An unknown flag BEFORE --message is refused; AFTER --message it is
# (correctly) message text, since --message is terminal by design.
fc alice 'request file --bogus --slug x --message hi' >/dev/null 2>&1
assert_rc "unknown file flag (pre-message) refused" "$?" "12"

echo "== 5. not-registered (rc10) / bad principal (rc11) =="
# Point at a registry with NO nexus-remote-ssh row → not enabled → refuse 10.
: > "$WORK/empty.registry"
SSH_ORIGINAL_COMMAND='request file --slug x --message hi' NEXUS_SERVICES_REGISTRY="$WORK/empty.registry" \
    bash "$FC" alice </dev/null >/dev/null 2>&1
assert_rc "not-registered → refuse rc10" "$?" "10"
fc '../etc' 'request file --slug x --message hi' >/dev/null 2>&1
assert_rc "path-ish principal refused rc11" "$?" "11"
fc '' 'request file --slug x --message hi' >/dev/null 2>&1
assert_rc "empty principal refused rc11" "$?" "11"

echo "== 6. await: ownership-scoped to the calling principal =="
aid=$(fc alice 'request file --reply required --slug owned --message mine')
_claim "$aid"
"$RC" reply "$aid" --message "here is your answer" >/dev/null
# alice can read her own reply (rc0)
arc=0; out=$(fc alice "request await $aid --timeout 0") || arc=$?   # #1403
assert_rc "owner await rc0" "$arc" "0"
assert_contains "owner sees ## Reply" "$out" "here is your answer"
# bob cannot read alice's reply (ownership check, rc5)
fc bob "request await $aid --timeout 0" >/dev/null 2>&1
assert_rc "cross-principal await denied rc5" "$?" "5"
# traversal / smuggled flags on await
fc alice 'request await ../../etc/passwd' >/dev/null 2>&1
assert_rc "traversal id on await refused rc12" "$?" "12"
fc alice "request await $aid --principal remote-bob" >/dev/null 2>&1
assert_rc "await --principal smuggle refused rc12" "$?" "12"
fc alice "request await $aid --interval 1" >/dev/null 2>&1
assert_rc "await --interval smuggle refused rc12" "$?" "12"

echo "== 7. fetch: path-confined, selector enum =="
# no-publish request, materialize results into the reply dir, fetch as owner
nid=$(fc carol 'request file --reply required --no-publish --slug nopub --message do it quietly')
_claim "$nid"
printf 'final results here\n' > "$WORK/results.src"
"$RC" reply "$nid" --no-publish --results "$WORK/results.src" --message "see fetch" >/dev/null
frc=0; out=$(fc carol "request fetch $nid results") || frc=$?   # #1403
assert_rc "owner fetch results rc0" "$frc" "0"
assert_contains "fetched results content" "$out" "final results here"
fc dave "request fetch $nid results" >/dev/null 2>&1
assert_rc "cross-principal fetch denied rc5" "$?" "5"
fc carol "request fetch $nid ../../etc/passwd" >/dev/null 2>&1
assert_rc "fetch bad selector refused rc12" "$?" "12"
fc carol 'request fetch ../../etc progress' >/dev/null 2>&1
assert_rc "fetch traversal id refused rc12" "$?" "12"
fc carol "request fetch $nid progress extra" >/dev/null 2>&1
assert_rc "fetch extra arg refused rc12" "$?" "12"

echo "== 7s. fetch status: read-only rename-state sub-mode, NO new top-level verb =="
# nexus-request observes ACTIVE PROCESSING via `fetch <id> status` — a
# READ-ONLY sub-mode of the ALREADY-ALLOWED fetch verb (not a new top-level
# verb). It must be ownership-scoped exactly like progress/results.
sid=$(fc carol 'request file --reply required --slug statectl --message watch me')
sout=$(fc carol "request fetch $sid status"); assert_rc "owner fetch status rc0" "$?" "0"
assert_contains "status reports 'new' before claim" "$sout" "new"
_claim "$sid"
sout=$(fc carol "request fetch $sid status")
assert_contains "status reports 'claimed' after claim" "$sout" "claimed"
# ownership: a foreign principal is denied (rc5), same as progress/results.
fc dave "request fetch $sid status" >/dev/null 2>&1
assert_rc "cross-principal fetch status denied rc5" "$?" "5"
# `status` did NOT become a top-level verb: `request status <id>` is unknown.
fc carol "request status $sid" >/dev/null 2>&1
assert_rc "no new top-level 'request status' verb (rc12)" "$?" "12"
# a bare top-level `status` verb is likewise unknown.
fc carol 'status' >/dev/null 2>&1
assert_rc "bare 'status' verb unknown (rc12)" "$?" "12"
# a bogus fetch selector adjacent to status is still refused.
fc carol "request fetch $sid statuz" >/dev/null 2>&1
assert_rc "bogus selector 'statuz' refused rc12" "$?" "12"

echo "== 7b. ISSUE D: reply body round-trips BYTE-EXACT through the CLIENT path =="
# The bug the client actually hit: a script pulled over the channel came back
# corrupted (line-continuation backslashes collapsed, `printf \n` rendered as
# real newlines) — sha mismatch, install refused. Assert a backslash/escape/
# brace-laden body reproduces sha-IDENTICAL through the paths the CLIENT uses
# (await AND fetch results, via the forced command) — not merely on disk (an
# on-disk-only check passes while the client still gets garbage).
cat > "$WORK/canon.sh" <<'CANONEOF'
#!/bin/sh
set -eu
emit() { \
  printf 'a\tb\n'; \
  grep -E '^\d+\{2\}$' "$1"; \
}
json='{"k":"v\n","p":"a\\b","q":"\"x\""}'
CANONEOF
csha=$(sha256sum < "$WORK/canon.sh" | cut -d' ' -f1)
cid=$(fc alice 'request file --kind report --reply required --slug canon --message placeholder')
_claim "$cid"
"$RC" reply "$cid" --file "$WORK/canon.sh" --worker w >/dev/null   # orchestrator replies byte-exact
# CLIENT path: fetch results over the forced command → RAW body bytes.
fc alice "request fetch $cid results" > "$WORK/cfetch.body" 2>/dev/null
assert_eq "ISSUE D: fetch results (client path) sha == source" \
    "$(sha256sum < "$WORK/cfetch.body" | cut -d' ' -f1)" "$csha"
# CLIENT path: await over the forced command → envelope; extract body + sha.
fc alice "request await $cid --timeout 1" > "$WORK/cawait.full" 2>/dev/null
cal=$(grep -n '^## Reply$' "$WORK/cawait.full" | tail -1 | cut -d: -f1)
tail -n +$((cal + 2)) "$WORK/cawait.full" > "$WORK/cawait.body"
assert_eq "ISSUE D: await body (client path) sha == source" \
    "$(sha256sum < "$WORK/cawait.body" | cut -d' ' -f1)" "$csha"

echo "== 8. attach: opt-in + pinned read-only, un-wideable =="
# default: attach disabled → refuse 13
fc alice 'attach' >/dev/null 2>&1
assert_rc "attach disabled by default rc13" "$?" "13"
# enabled: bare `attach` execs the PINNED `tmux attach -t nexus -r`
rm -f "$WORK/tmux-argv"
SSH_ORIGINAL_COMMAND='attach' MONITOR_REMOTE_ALLOW_ATTACH=true \
    PATH="$STUB:$PATH" bash "$FC" alice </dev/null >/dev/null 2>&1
argv=$(cat "$WORK/tmux-argv" 2>/dev/null || echo "")
assert_eq "attach pinned to read-only nexus" "$argv" "attach -t nexus -r"
# attach is strict: ANY client args are refused (cannot drop -r or retarget)
rm -f "$WORK/tmux-argv"
MONITOR_REMOTE_ALLOW_ATTACH=true fc alice 'attach -t evil -X kill-server' >/dev/null 2>&1
assert_rc "attach with client args refused rc12" "$?" "12"
assert_no_file "refused attach never invoked tmux" "$WORK/tmux-argv"

echo "== 8b. self-describing policy notice (NO in-nexus expansion intake) =="
# bare connection (no command) → LEAN policy notice, rc0
rc=0; out=$(SSH_ORIGINAL_COMMAND='' PATH="$STUB:$PATH" bash "$FC" alice </dev/null) || rc=$?   # #1403
assert_rc "bare connection → rc0 (informational)" "$rc" "0"
assert_contains "notice states command policy"      "$out" "command policy: channel-only"
assert_contains "notice states RESTRICTED access"   "$out" "RESTRICTED"
# the notice points the client to ITS OWN operator (out-of-band), NOT a nexus verb
assert_contains "notice points to the client's own operator" "$out" "YOUR OWN operator"
assert_contains "notice states no in-channel grant"          "$out" "NO command to grant it"
# bare connection stays LEAN — it does NOT carry the full onboarding (that is
# delivered only on the explicit policy/help verb; banner stays terse).
assert_not_contains "bare connection omits the full onboarding" "$out" "RECAP, not a new contract"

echo "== 8c. policy/help/onboarding deliver the FULL post-connect onboarding =="
# explicit `policy` verb → lean notice header PLUS the moved usage material.
prc=0; out=$(SSH_ORIGINAL_COMMAND='policy' PATH="$STUB:$PATH" bash "$FC" alice </dev/null) || prc=$?   # #1403
assert_rc "policy verb rc0" "$prc" "0"
assert_contains "policy keeps the notice header"   "$out" "nexus remote agent channel"
assert_contains "policy includes onboarding recap" "$out" "RECAP, not a new contract"
assert_contains "policy includes why-not-C2"       "$out" "COMMAND-AND-CONTROL BACKCHANNEL"
assert_contains "policy includes usage examples"   "$out" "request file --kind question"
assert_contains "policy includes capability note"  "$out" "on-request capability"
assert_contains "policy defers to operator prompt" "$out" "operator-supplied prompt"
# The onboarding now points new clients at nexus-request (the one-call primitive)
# and mentions the rename-state processing event.
assert_contains "policy points at nexus-request"   "$out" "nexus-request"
assert_contains "policy mentions processing state" "$out" "state=processing"
# `help` and `onboarding` are aliases → identical full onboarding.
hout=$(SSH_ORIGINAL_COMMAND='help' PATH="$STUB:$PATH" bash "$FC" alice </dev/null)
assert_eq "help == policy output" "$hout" "$out"
oout=$(SSH_ORIGINAL_COMMAND='onboarding' PATH="$STUB:$PATH" bash "$FC" alice </dev/null)
assert_eq "onboarding == policy output" "$oout" "$out"
# strict about args under every spelling
SSH_ORIGINAL_COMMAND='policy --leak /etc/passwd' bash "$FC" alice </dev/null >/dev/null 2>&1
assert_rc "policy with args refused rc12" "$?" "12"
SSH_ORIGINAL_COMMAND='help me' bash "$FC" alice </dev/null >/dev/null 2>&1
assert_rc "help with args refused rc12" "$?" "12"
# CRITICAL: there is NO in-nexus expansion-request intake verb (the nexus
# must never have a path that could auto-expand). `request expand` is refused.
fc alice 'request expand --justification give me a shell' >/dev/null 2>&1
assert_rc "request expand has NO intake → refused rc12" "$?" "12"

echo "== 9. every invocation is audit-logged =="
assert_file_exists "forced-command audit log exists" "$NEXUS_REMOTE_LOG"
logc=$(cat "$NEXUS_REMOTE_LOG")
assert_contains "log records a REFUSED line" "$logc" "REFUSED"
assert_contains "log records principal"      "$logc" "principal=alice"
# the request BODY must never be logged (it may carry task content)
assert_not_contains "message body NOT in audit log" "$logc" "Summarize work foo please"


# ── REFUSAL-ARM COVERAGE (your-org/nexus-code#1279) ────────────────────
# 38 of the 43 refusal arms in the wrapper share rc12, so an rc-only
# assertion cannot say WHICH guard fired — a test asserting rc12 can be
# satisfied by a completely different arm, which is how four arms sat
# unexercised behind a green suite. Assert the arm's OWN message too.
assert_refused() {
    local label="$1" want_rc="$2" needle="$3" principal="$4" cmd="$5" input="${6-}"
    local err rc
    rc=0; err=$(fc "$principal" "$cmd" "$input" 2>&1 >/dev/null) || rc=$?   # #1403
    if [[ "$rc" == "$want_rc" && "$err" == *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else
        printf '  FAIL: %s — rc %s want %s; stderr=[%s] wanted substring [%s]\n' \
            "$label" "$rc" "$want_rc" "$err" "$needle" >&2; FAIL=$((FAIL+1))
    fi
}

echo "== 10a. value-consuming flags: the value-missing arms (#1279 class) =="
# MECHANISM: these arms are `shift 2 || refuse`, and `shift 2` fails ONLY when
# the flag is the LAST token. With any token after it the flag consumes that
# token instead — and after `--message` (terminal by design) a trailing flag is
# merely body text, rc0. So the flag must be final, or the arm is not reached.
assert_refused "--kind as the final token → needs a value"     12 "--kind needs a value"     alice 'request file --slug x --kind'
assert_refused "--slug as the final token → needs a value"     12 "--slug needs a value"     alice 'request file --slug'
assert_refused "--priority as the final token → needs a value" 12 "--priority needs a value" alice 'request file --slug x --priority'
assert_refused "--reply as the final token → needs a value"    12 "--reply needs a value"    alice 'request file --slug x --reply'
assert_refused "--timeout as the final token → needs seconds"  12 "--timeout needs seconds"  alice 'request await abc123 --timeout'

echo "== 10b. request file: field validation arms =="
assert_refused "no --slug at all → --slug is required" 12 "request file: --slug is required"            alice 'request file --kind question --message hi'
assert_refused "--slug charset enforced"               12 "request file: --slug must be [A-Za-z0-9_-]"  alice 'request file --slug bad/slug --message hi'
assert_refused "--kind must be a kebab token"          12 "request file: --kind must be a kebab token"  alice 'request file --slug x --kind BadKind --message hi'
assert_refused "--message present but empty"           12 "request file: --message is empty"            alice 'request file --slug x --message'
# #1279 arm (line 202 at 989b8880): the --priority enum's default-deny.
assert_refused "#1279: --priority enum rejects a third value" 12 "request file: --priority must be normal|high" \
    alice 'request file --slug x --priority urgent --message hi'
# POSITIVE CONTROL — the enum is not merely refusing everything: both
# allowed values must still be ACCEPTED end-to-end.
pnid=$(fc alice 'request file --slug pri-normal --priority normal --message hi'); assert_rc "--priority normal accepted rc0" "$?" "0"
assert_file_exists "--priority normal request written" "$REQ/$pnid.new.md"
phid=$(fc alice 'request file --slug pri-high --priority high --message hi');     assert_rc "--priority high accepted rc0"   "$?" "0"
assert_file_exists "--priority high request written"   "$REQ/$phid.new.md"

# #1279 arm (line 292): NO body supplied at all — neither --message nor
# --message-stdin. The `case "$msg_mode"` default-deny arm.
bodyless_pre=$(find "$REQ" -maxdepth 1 -name '*.new.md' 2>/dev/null | wc -l)
assert_refused "#1279: request file with no body at all" 12 "request file: a body is required" \
    alice 'request file --slug nobody --kind question'
bodyless_post=$(find "$REQ" -maxdepth 1 -name '*.new.md' 2>/dev/null | wc -l)
assert_eq "no request created for a bodyless request file" "$bodyless_post" "$bodyless_pre"

echo "== 10c. request file: body staging failure is refused, not ignored =="
# mktemp must fail: point the principals dir BELOW a regular file so the
# defensive mkdir -p cannot create it. (A chmod-500 dir would work too but
# would defeat the suite's `rm -rf "$WORK"` EXIT trap.)
: > "$WORK/notadir"
stage_err=$(SSH_ORIGINAL_COMMAND='request file --slug stage --message-stdin' \
    MONITOR_REMOTE_PRINCIPALS_DIR="$WORK/notadir/sub" PATH="$STUB:$PATH" \
    bash "$FC" alice </dev/null 2>&1 >/dev/null); stage_rc=$?
assert_rc "unstageable body refused rc12" "$stage_rc" "12"
assert_contains "…with the staging arm's own message" "$stage_err" "request file: cannot stage the body"

echo "== 10d. await: the flag loop's DEFAULT-DENY arm (#1279) =="
assert_refused "await with no id"                    12 "request await: <id> required"              alice 'request await'
# #1279 arm (line 309). A default-deny arm that nothing had ever taken is
# precisely the arm that cannot be assumed to work. Two shapes reach it.
# `--timeout 0` is NOT decoration: it bounds what happens when the arm is
# BROKEN. A neutered default-deny arm (`*) shift ;;`) falls through to a real
# `ng request await`, which with no timeout BLOCKS — so the suite would hang
# instead of failing, and a hang is a far worse signal than a red. Bounded,
# the mutant returns rc4 promptly and the assertion fails cleanly.
assert_refused "#1279: await default-deny — unknown flag" 12 "request await: disallowed flag/argument" alice 'request await abc123 --timeout 0 --bogus'
assert_refused "#1279: await default-deny — bare extra positional" 12 "request await: disallowed flag/argument" alice 'request await abc123 --timeout 0 extra'
assert_refused "await --timeout must be an integer"  12 "request await: --timeout must be an integer" alice 'request await abc123 --timeout 5s'

echo "== 10e. fetch: missing id =="
assert_refused "fetch with no id" 12 "request fetch: <id> required" alice 'request fetch'

echo "== 10f. command-line byte screen (#1279) + the no-verb arm =="
# #1279 arm (line 411). It sits one line below the newline-smuggling check
# that IS covered (section 2c). It screens the TOKEN STREAM — four vectors:
assert_refused "#1279: SOH 0x01 control byte" 12 "non-printable byte in command" alice $'request file --slug x --message a\x01b'
assert_refused "#1279: ESC 0x1b (terminal-escape injection vector)" 12 "non-printable byte in command" alice $'request file --slug x --message a\x1b[31mb'
assert_refused "#1279: DEL 0x7f"              12 "non-printable byte in command" alice $'request file --slug x --message a\x7fb'
assert_refused "#1279: raw high byte 0x80"    12 "non-printable byte in command" alice $'request file --slug x --message a\x80b'
# POSITIVE CONTROL — the screen is not simply refusing everything: a TAB is
# C-locale [:space:] and must still pass, or the guard would be over-broad.
tabid=$(fc alice $'request file --slug tabbody --message a\tb'); assert_rc "TAB in an inline body still accepted (screen not over-broad)" "$?" "0"
assert_file_exists "tab-body request written" "$REQ/$tabid.new.md"
# The screen is DELIBERATELY LC_ALL=C (see the wrapper's locale note), so a
# multi-byte UTF-8 character on the COMMAND LINE is refused as a raw high
# byte. Pinned because clients hit it, and because it is the boundary of what
# this arm claims: it guards TOKENS, not body content…
assert_refused "multi-byte UTF-8 on the command line refused (LC_ALL=C, by design)" \
    12 "non-printable byte in command" alice $'request file --slug x --message caf\xc3\xa9'
# …and the byte-exact body channel is the counterpart: the SAME bytes ride
# --message-stdin untouched, because stdin is not the command line. Asserting
# the pair stops the screen from being mistaken for a body sanitizer.
u8id=$(fc alice 'request file --slug utf8-stdin --message-stdin' 'café — π'); assert_rc "the same UTF-8 rides --message-stdin (rc0)" "$?" "0"
assert_contains "utf-8 body preserved byte-exact through stdin" "$("$RC" show "$u8id")" "café — π"
# The no-verb arm: CMD is non-empty (so it is past the bare-connection
# branch) yet splits to zero tokens.
assert_refused "whitespace-only command → no verb" 12 "no verb" alice '   '

echo "== 11. RATCHET: every refusal arm is declared AND exercised (#1279) =="
# THE CLASS FIX. #1279 was found by an out-of-band coverage+mutation audit;
# nothing in the suite could have reported it, so a NEW unexercised arm would
# be another audit finding rather than a red. This section closes that:
#
#   (a) POPULATION — the set of `refuse` arms in the wrapper must equal the
#       manifest below. Add, delete or reword an arm and this goes RED, so a
#       new guard cannot be added to the confinement boundary without a
#       deliberate decision about whether it is tested.
#   (b) EXERCISE — every arm marked `covered` must appear in THIS run's audit
#       log. `refuse()` logs `REFUSED(<code>): <message>` before exiting, so
#       the log is a precise record of which arms actually fired — unlike line
#       coverage, which cannot separate `[[ check ]] || refuse` on one line
#       and reported 15 of these arms as covered when they had never run.
#
# Two arms are `exempt`, each with its reason recorded inline.
_arm_needle() {   # <code> <source message> → the literal audit-log needle
    local code="$1" msg="$2" pre="${msg%%\$*}"
    # One arm's message STARTS with a variable ("$VERB takes no arguments").
    # Key it on a spelling this suite actually produces, so it cannot be
    # falsely attested by the neighbouring "attach takes no arguments" arm.
    [[ -z "$pre" ]] && { printf 'REFUSED(%s): policy%s' "$code" "${msg#\$VERB}"; return; }
    printf 'REFUSED(%s): %s' "$code" "$pre"
}

# Extract with grep -o (not a line-oriented sed): line 202 packs a whole
# case/esac onto one line, and a future line could carry two arms.
grep -o 'refuse [0-9]\{1,3\} "[^"]*"' "$FC" \
    | sed 's/refuse \([0-9]*\) "\(.*\)"/\1@@\2/' | sort > "$WORK/arms.extracted"

# Manifest: <status>@@<exit code>@@<message exactly as written in the source>.
# `@@` is safe as a separator — no arm message contains `@`.
sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' > "$WORK/arms.manifest.raw" <<'MANIFEST'
covered@@12@@--kind needs a value
covered@@12@@--slug needs a value
covered@@12@@--priority needs a value
covered@@12@@--reply needs a value
covered@@12@@--origin is forced server-side (cannot be client-supplied)
covered@@12@@--principal is not accepted from a remote client
covered@@12@@--file (server path) is not accepted; use --message / --message-stdin
covered@@12@@stdin sentinel '-' not accepted; use --message-stdin
covered@@12@@request file: disallowed flag/argument: '$1'
covered@@12@@request file: --slug is required
covered@@12@@request file: --slug must be [A-Za-z0-9_-]
covered@@12@@request file: --kind must be a kebab token
covered@@12@@request file: --priority must be normal|high
covered@@12@@request file: --reply accepts required|optional|none
covered@@12@@request file: cannot stage the body
covered@@12@@request file: body exceeds ${cap} bytes (REMOTE_BODY_MAX_BYTES)
covered@@12@@request file: --checksum requires --message-stdin (an inline body is whitespace-joined from argv, so there is no byte-exact client-side reference to verify against)
covered@@12@@request file: --message is empty
covered@@12@@request file: ambiguous '-' body; use --message-stdin
covered@@12@@request file: a body is required (--message TEXT… or --message-stdin)
covered@@12@@request await: <id> required
covered@@12@@request await: illegal id (must be [A-Za-z0-9_-])
covered@@12@@--timeout needs seconds
covered@@12@@request await: --interval is server-controlled
covered@@12@@request await: --principal is forced server-side
covered@@12@@request await: disallowed flag/argument: '$1'
covered@@12@@request await: --timeout must be an integer
covered@@12@@request fetch: <id> required
covered@@12@@request fetch: illegal id (must be [A-Za-z0-9_-])
covered@@12@@request fetch: selector must be progress|results|status
covered@@12@@request fetch: unexpected argument: '${1:-}'
covered@@13@@attach is disabled (monitor.remote.allow_attach != true; request-only posture)
# EXEMPT — reaching this needs a PATH with NO tmux, and the nexus shell
#          prelude ($BASH_ENV) re-prepends monitor/tmuxwrap into every
#          non-interactive bash: measured, a curated 1193-binary PATH
#          excluding /usr/bin/tmux STILL resolved tmux. Not buildable
#          hermetically here. Its sibling rc13 arm (attach disabled) IS
#          covered, so the attach gate itself is exercised.
exempt@@13@@tmux not found — cannot attach
covered@@10@@remote channel not registered (the service is not enabled)
covered@@11@@missing/invalid principal in authorized_keys command= (got: '${PRINCIPAL}')
# EXEMPT — gate 3 (source-address pin) is asserted in
#          test-remote-source-enforcement.sh. THIS fixture pins
#          from_cidr="" and supplies SSH_CLIENT on purpose (header note),
#          so the arm cannot fire here by construction.
exempt@@14@@source address rejected: $_REMOTE_SRC_REASON
covered@@12@@newline in command (argument smuggling)
covered@@12@@non-printable byte in command
covered@@12@@no verb
covered@@12@@unknown request subcommand: '${SUB}' (allowed: file|await|fetch)
covered@@12@@$VERB takes no arguments
covered@@12@@attach takes no arguments
covered@@12@@unknown verb: '${VERB}' (allowed: request file|await|fetch; policy|help|onboarding; attach)
MANIFEST

sed 's/^[a-z]*@@//' "$WORK/arms.manifest.raw" | sort > "$WORK/arms.declared"

# (a) POPULATION ratchet.
undeclared=$(comm -23 "$WORK/arms.extracted" "$WORK/arms.declared")
stale=$(comm -13 "$WORK/arms.extracted" "$WORK/arms.declared")
if [[ -z "$undeclared" ]]; then printf '  PASS: every refuse arm in the wrapper is declared\n'; PASS=$((PASS+1))
else printf '  FAIL: refuse arm(s) NOT in the manifest — declare covered/exempt:\n%s\n' "$undeclared" >&2; FAIL=$((FAIL+1)); fi
if [[ -z "$stale" ]]; then printf '  PASS: no stale manifest entry\n'; PASS=$((PASS+1))
else printf '  FAIL: manifest declares arm(s) absent from the wrapper:\n%s\n' "$stale" >&2; FAIL=$((FAIL+1)); fi
# Population sanity: a silently empty extraction would pass both set
# comparisons against an equally empty manifest.
armcount=$(wc -l < "$WORK/arms.extracted")
if (( armcount >= 40 )); then printf '  PASS: extraction found %s refusal arms (sane, non-empty)\n' "$armcount"; PASS=$((PASS+1))
else printf '  FAIL: extraction found only %s refusal arms — the instrument is broken\n' "$armcount" >&2; FAIL=$((FAIL+1)); fi

# (b) EXERCISE: each `covered` arm must have fired in THIS run.
missed=""; covered_n=0; badneedle=""
while IFS= read -r line; do
    [[ "$line" == covered@@* ]] || continue
    body="${line#covered@@}"; code="${body%%@@*}"; msg="${body#*@@}"
    covered_n=$((covered_n + 1))
    needle=$(_arm_needle "$code" "$msg")
    # SHAPE, not emptiness-as-validity: `grep -qF -- ""` matches EVERY line, so
    # an empty or malformed needle would turn this whole check into a vacuous
    # pass — the failure mode that looks exactly like success.
    [[ "$needle" =~ ^REFUSED\([0-9]+\):\ .+$ ]] || badneedle+="  ${code}: ${msg} -> [${needle}]"$'\n'
    grep -qF -- "$needle" "$NEXUS_REMOTE_LOG" || missed+="  ${code}: ${msg}"$'\n'
done < "$WORK/arms.manifest.raw"
if [[ -z "$badneedle" ]]; then printf '  PASS: every derived audit-log needle is well-formed (non-vacuous)\n'; PASS=$((PASS+1))
else printf '  FAIL: malformed/empty needle(s) — the exercise check below would be vacuous:\n%s' "$badneedle" >&2; FAIL=$((FAIL+1)); fi
if [[ -z "$missed" ]]; then printf '  PASS: all %s arms declared covered actually fired in this run\n' "$covered_n"; PASS=$((PASS+1))
else printf '  FAIL: arm(s) declared covered but never fired (unexercised guard on the confinement boundary):\n%s' "$missed" >&2; FAIL=$((FAIL+1)); fi

th_summary_and_exit
