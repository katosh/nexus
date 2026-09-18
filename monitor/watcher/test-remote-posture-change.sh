#!/usr/bin/env bash
# Tests for the POSTURE-CHANGE ORDERING precondition (defect 3) and the
# PIN-MEANING reporting primitives (defect 9).
#
# DEFECT 3 — A LOCKED-OUT CLIENT CANNOT ASK THIS CHANNEL WHY IT IS LOCKED OUT.
# `from=` is written at ENROLL time only, so a credential enrolled before a pin
# existed carries no source restriction; #609 made that gap LOUD and refuses
# where nothing enforces the pin at all. What remained is ORDERING. A guard that
# merely refuses tells the OPERATOR something is wrong, but once the posture
# actually moves, the channel the client would use to ask about the lockout is
# the thing that broke — full pre-auth banner, then `Permission denied
# (publickey)`, and no route to ask why. The printed remedy made it worse by
# being destructive-first (`revoke` THEN `enroll-invite`): revoking deletes the
# only credential the client has before its replacement exists, which IS the
# lockout, performed deliberately.
#
# So the SEQUENCE is what must be enforceable, not the end state: a routable
# posture change is refused unless a LIVE invitation already exists for every
# principal it would strand.
#
# THE REMEDY HAD THE SAME BUG INSIDE IT, and this suite pins the fix (test 5).
# Once config is edited to a routable bind, _remote_from_pin_list returns only
# the LAN CIDR — so an enroll line written with it REFUSES the client that is
# still arriving over the OLD loopback carrier, pre-auth, before the enroll
# session can run. The invitation would be unredeemable. The ENROLL line now
# carries the UNION of the recorded and configured pins; the PERMANENT line the
# enroll session reconstructs still uses the configured one.
#
# DEFECT 9 — THE PIN CONSTRAINS THE LAST HOP, NOT THE CLIENT. Measured on a live
# install: the configured from_cidr resolved to the campus BASTION, and it had
# to, because an off-site client cannot reach the compute node directly — the
# connection necessarily arrives FROM the bastion. Such a pin authenticates
# shared infrastructure and constrains nothing about WHICH client, while reading
# in authorized_keys as a client restriction. That is the third instance of one
# family in this subsystem and the sharpest, because unlike the other two the
# pin is PRESENT and CORRECTLY WRITTEN — it survives every absence check. We
# cannot decide the topology from inside the sandbox and must not pretend to, so
# the fix REPORTS the shape rather than returning a verdict.
#
#   1. loopback postures strand nobody — the guard stays out of the way
#   2. a routable move with an unpinned credential is REFUSED, and NAMES the
#      principal (not a line number — the remedy takes --principal)
#   3. a LIVE invitation for that principal releases the guard …
#   4. … and an EXPIRED one does not (the potency control for test 3)
#   5. the invitation is reachable from the OLD posture: the enroll pin is the
#      UNION while a change is pending, and unchanged when none is
#   6. fail-closed: unauditable credentials / unreadable invitation store REFUSE
#   7. an unchanged posture is not a move (re-runs do not break a live endpoint)
#   8. the audit names principals — with the BASH_REMATCH clobber regression
#   9. pin CLASS + MEANING: single-host says what it does not establish
#
# Run: bash monitor/watcher/test-remote-posture-change.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

REPO=$(cd "$_test_dir/../.." && pwd)
MON="$REPO/monitor"
LIB="$MON/_remote_lib.sh"
[[ -r "$LIB" ]] || th_abort "missing $LIB"

WORK=$(mktemp -d "/tmp/tt-$$-posture.XXXXXX") || th_abort "mktemp failed"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAK"

# A throwaway principals dir. NOTHING here touches the live endpoint: HOME is
# redirected, so _remote_principals_dir resolves inside the fixture.
new_home() {
    local h="$WORK/$1"
    rm -rf "$h"; mkdir -p "$h/.claude/nexus-remote/enroll"
    chmod 700 "$h/.claude/nexus-remote"
    printf '%s' "$h"
}
ak_of() { printf '%s/.claude/nexus-remote/authorized_keys' "$1"; }

# Write a channel-only credential for <principal>, optionally with a from= pin.
put_cred() {  # put_cred <home> <principal> [from]
    local h="$1" p="$2" from="${3:-}" opts
    opts="command=\"$MON/remote-forced-command.sh $p\",restrict"
    [[ -n "$from" ]] && opts="$opts,from=\"$from\""
    printf '%s %s %s@nexus-remote\n' "$opts" "$KEY" "$p" >> "$(ak_of "$h")"
    chmod 600 "$(ak_of "$h")"
}

put_invite() {  # put_invite <home> <principal> <ttl_offset_seconds>
    local h="$1" p="$2" off="$3" hash
    # 64 hex, unique per principal so records do not collide.
    hash=$(printf '%s' "$p" | sha256sum | awk '{print $1}')
    printf 'principal=%s\nexpires=%s\n' "$p" "$(( $(date +%s) + off ))" \
        > "$h/.claude/nexus-remote/enroll/$hash.token"
    chmod 600 "$h/.claude/nexus-remote/enroll/$hash.token"
}

put_posture() { printf '%s\n' "$2" > "$1/.claude/nexus-remote/posture"; }

# Run a lib function under a fixture HOME + posture. Echoes output, then RC=<n>.
inlib() {  # inlib <home> <bind> <cidr> <shell-snippet>
    HOME="$1" MONITOR_REMOTE_BIND_ADDRESS="$2" MONITOR_REMOTE_FROM_CIDR="$3" \
        bash -c ". '$LIB'; $4"' ; printf "RC=%s\n" "$?"' 2>&1
}
guard() { inlib "$1" "$2" "$3" '_remote_posture_change_guard'; }
rc_of() { printf '%s' "$1" | awk -F= '/^RC=/{print $2}' | tail -1; }

# ── 1. loopback strands nobody ────────────────────────────────────────
echo "== 1. a loopback posture is never a stranding move"
H=$(new_home lb); put_cred "$H" alpha
out=$(guard "$H" 127.0.0.1 "10.0.0.0/8")
assert_eq "loopback + unpinned credential → allowed" "$(rc_of "$out")" "0"

# ── 2. a routable move is refused, and names the PRINCIPAL ────────────
echo "== 2. a routable move with an unpinned credential is REFUSED, by name"
H=$(new_home r1); put_cred "$H" alpha; put_cred "$H" bravo
# A RECORDED prior posture is required for this to be a CHANGE. Without one the
# guard takes the baseline arm (warn, proceed) — see test 11.
put_posture "$H" 'bind=loopback pin=10.0.0.0/8,127.0.0.1/32,::1/128'
out=$(guard "$H" 10.9.9.9 "10.0.0.0/8")
assert_eq "routable move + unpinned + no invitation → REFUSED" "$(rc_of "$out")" "1"
assert_contains "names the first principal"  "$out" "--principal alpha"
assert_contains "names the second principal" "$out" "--principal bravo"
# The ORDERING is the point, so assert the text actually teaches it.
assert_contains "states the bootstrapping reason" "$out" "cannot ask this channel"
assert_contains "puts the invitation BEFORE the move" "$out" "BEFORE the move"
assert_contains "warns against revoking first" "$out" "Do NOT \`revoke\` first"
# NOT a line-number-only diagnosis (the pre-fix shape).
assert_not_contains "does not fall back to a bare line tag" "$out" "--principal line"

# ── 3. AN INVITATION DOES NOT RELEASE THE GUARD — RE-ENROLMENT DOES ───
# THE S2 INVERSION, and the whole point of this section. The release used to be
# a disjunction: this arm, OR "a live invitation exists for every stranded
# principal". Measured, that second disjunct was reachable ONLY in the state
# where the client had NOT yet enrolled — because `remote-enroll.sh` REPLACES a
# principal's line on redemption, so once the client redeems, the
# credential-fits arm carries the case by itself. It opened the gate before the
# client was safe and shut it after. On the guard's headline scenario
# (loopback -> routable) what moves is REACHABILITY, not the pin: the listener
# the client reaches is gone and the outstanding invitation is unredeemable.
echo "== 3. an outstanding invitation does NOT release the guard (S2)"
put_invite "$H" alpha 900; put_invite "$H" bravo 900
out=$(guard "$H" 10.9.9.9 "10.0.0.0/8")
assert_eq "both invited but NEITHER enrolled → still REFUSED" "$(rc_of "$out")" "1"
assert_contains "and says the gate opens on re-enrolment" "$out" "OPENS ON RE-ENROLMENT"
# The invitation is now DIAGNOSTIC: it must stop the operator issuing a duplicate.
assert_contains "an outstanding invitation is reported as such" "$out" "ALREADY OUTSTANDING"
assert_not_contains "and no duplicate invite is suggested for it" "$out" "--principal alpha"

# ── 4. REDEMPTION is what releases it ─────────────────────────────────
echo "== 4. the guard opens once every principal has actually re-enrolled"
# Redemption REPLACES the line with one carrying the new posture's pin — which
# is exactly what `_remote_from_pin_list` writes, so model it that way.
: > "$(ak_of "$H")"
put_cred "$H" alpha "10.0.0.0/8"
put_cred "$H" bravo "10.0.0.0/8"
out=$(guard "$H" 10.9.9.9 "10.0.0.0/8")
assert_eq "both re-enrolled → ALLOWED" "$(rc_of "$out")" "0"
# POTENCY CONTROL: one still on the old credential must hold the gate shut, or
# the pass above is a guard that stopped looking rather than one that opened.
: > "$(ak_of "$H")"
put_cred "$H" alpha "10.0.0.0/8"
put_cred "$H" bravo
out=$(guard "$H" 10.9.9.9 "10.0.0.0/8")
assert_eq "one still un-re-enrolled → REFUSED" "$(rc_of "$out")" "1"
assert_contains "names the one that has not re-enrolled" "$out" "posture: bravo"
assert_not_contains "and not the one that has" "$out" "posture: alpha"

# ── 5. the invitation must be reachable from the OLD posture ──────────
echo "== 5. the enroll pin is the UNION while a posture change is pending"
H=$(new_home tr)
put_posture "$H" 'bind=loopback pin=10.0.0.0/8,127.0.0.1/32,::1/128'
# Config has already moved to routable: the plain list drops loopback.
plain=$(inlib "$H" 10.9.9.9 "10.0.0.0/8" 'printf "%s" "$(_remote_from_pin_list)"')
trans=$(inlib "$H" 10.9.9.9 "10.0.0.0/8" 'printf "%s" "$(_remote_from_pin_list_transitional)"')
assert_not_contains "the PERMANENT pin is the new posture's only" "${plain%RC=*}" "127.0.0.1/32"
assert_contains "the ENROLL pin still admits the old carrier peer" "${trans%RC=*}" "127.0.0.1/32"
assert_contains "and still carries the new posture's pin"          "${trans%RC=*}" "10.0.0.0/8"
# NEGATIVE CONTROL: with no pending change the two must be identical, or this
# silently widens every ordinary enrollment.
H2=$(new_home tr2)
put_posture "$H2" 'bind=routable pin=10.0.0.0/8'
p2=$(inlib "$H2" 10.9.9.9 "10.0.0.0/8" 'printf "%s" "$(_remote_from_pin_list)"')
t2=$(inlib "$H2" 10.9.9.9 "10.0.0.0/8" 'printf "%s" "$(_remote_from_pin_list_transitional)"')
assert_eq "no pending change → transitional == plain" "${t2%RC=*}" "${p2%RC=*}"

# ── 6. fail-closed on an unreadable store ─────────────────────────────
echo "== 6. fail-closed: what cannot be verified is NAMED, never passed"
H=$(new_home fc); put_cred "$H" alpha
put_posture "$H" 'bind=loopback pin=10.0.0.0/8,127.0.0.1/32,::1/128'
chmod 000 "$(ak_of "$H")"
out=$(guard "$H" 10.9.9.9 "10.0.0.0/8")
assert_eq "unauditable authorized_keys → REFUSED" "$(rc_of "$out")" "1"
assert_contains "and says why" "$out" "must not read as"
chmod 600 "$(ak_of "$H")"
chmod 000 "$H/.claude/nexus-remote/enroll"
out=$(guard "$H" 10.9.9.9 "10.0.0.0/8")
# Since S2 the invitation store cannot RELEASE the guard, only inform the
# remedy — so an unreadable one degrades the MESSAGE, never the verdict. That is
# strictly stronger than the previous fail-closed-on-enumeration behaviour,
# where the same input was load-bearing for the decision.
assert_eq "unreadable invitation store → still REFUSED" "$(rc_of "$out")" "1"
assert_contains "and names what it could not read" "$out" "could not read"
assert_contains "and warns against a duplicate invite" "$out" "duplicate"
chmod 700 "$H/.claude/nexus-remote/enroll"

# ── 7. an unchanged posture is not a move ─────────────────────────────
echo "== 7. a re-run at the SAME posture does not trip the guard"
H=$(new_home same); put_cred "$H" alpha
put_posture "$H" "$(inlib "$H" 10.9.9.9 '10.0.0.0/8' 'printf "%s" "$(_remote_posture_signature)"' | sed 's/RC=.*//')"
out=$(guard "$H" 10.9.9.9 "10.0.0.0/8")
assert_eq "same posture, unpinned credential → allowed (no outage on re-run)" "$(rc_of "$out")" "0"

# ── 8. the audit names principals (BASH_REMATCH clobber regression) ───
echo "== 8. the audit reports principals, not line numbers"
H=$(new_home aud); put_cred "$H" charlie
out=$(inlib "$H" 10.9.9.9 "10.0.0.0/8" \
    '_remote_from_audit "$(_remote_from_pin_list)" >/dev/null 2>&1; printf "P=%s\n" "$_REMOTE_FROM_AUDIT_UNPINNED_PRINCIPALS"')
assert_contains "captures the principal" "$out" "P=charlie"
# THE REGRESSION THIS PINS: _remote_valid_principal runs its own [[ =~ ]], which
# CLOBBERS BASH_REMATCH. Validating with BASH_REMATCH[2] and then ASSIGNING
# BASH_REMATCH[2] validated the right string and assigned the wrong one — the
# guard passed and the principal still came out blank, degrading every refusal
# to line numbers. Measured before the fix; this assertion is what keeps it.
assert_not_contains "and does not degrade to a line tag" "$out" "P=line"

# ── 9. pin class + meaning (defect 9 reporting) ───────────────────────
echo "== 9. the pin's MEANING is reportable, not silent"
H=$(new_home pin)
for spec in "10.0.0.0/8:range" "1.2.3.4/32:single-host" "0.0.0.0/0:any-source" "::/0:any-source" "2001:db8::1/128:single-host"; do
    cidr="${spec%:*}"; want="${spec##*:}"
    got=$(inlib "$H" 127.0.0.1 "$cidr" 'printf "%s" "$(_remote_pin_class)"')
    assert_eq "pin class of $cidr" "${got%RC=*}" "$want"
done
m=$(inlib "$H" 127.0.0.1 "1.2.3.4/32" 'printf "%s" "$(_remote_pin_meaning)"')
assert_contains "a /32 is conditioned on WHOSE address arrives" "$m" "ONLY IF"
assert_contains "names the mediating-hop hazard"                "$m" "bastion"
assert_contains "says the peer address is ground truth"         "$m" "ground truth"
assert_not_contains "and never calls a /32 max security"        "$m" "max security"
m=$(inlib "$H" 127.0.0.1 "10.0.0.0/8" 'printf "%s" "$(_remote_pin_meaning)"')
assert_contains "a subnet is broader by construction" "$m" "broader than any one client"

# A CLASSIFIER WITH NO `unknown` ARM DEFAULTS THE UNCLASSIFIABLE INTO A NAMED
# CLASS, and this one did: `${cidr##*/}` on a value carrying no `/` yields the
# whole string, misses every arm, and fell through to `range`. Measured at
# 27d1150: `10.0.0.5`, `not-a-cidr` and `10.0.0.0/99` were ALL reported as
# `range` — a garbage pin presented as a deliberate subnet, by the one function
# whose job is telling the operator what their pin means.
for bad in "10.0.0.5" "not-a-cidr" "10.0.0.0/99" "example.org/24"; do
    got=$(inlib "$H" 127.0.0.1 "$bad" 'printf "%s" "$(_remote_pin_class)"')
    assert_eq "a malformed pin ($bad) classifies as unknown, not range" "${got%RC=*}" "unknown"
done
# SINGLE-HOST IS FAMILY-DEPENDENT. A bare `32|128` arm reports an IPv6 /32 —
# a 2^96-address prefix — as "admits exactly ONE address", and _remote_bind_guard
# ACCEPTS that config, so the operator is handed a security misreport by the
# function whose only job is saying what the pin means. Measured at e50efc7:
# `2001:db8::/32` -> single-host.
assert_eq "IPv4 /32 is a single host" \
    "$(inlib "$H" 127.0.0.1 '1.2.3.4/32' 'printf "%s" "$(_remote_pin_class)"' | sed 's/RC=.*//')" "single-host"
assert_eq "IPv6 /128 is a single host" \
    "$(inlib "$H" 127.0.0.1 '2001:db8::1/128' 'printf "%s" "$(_remote_pin_class)"' | sed 's/RC=.*//')" "single-host"
assert_eq "IPv6 /32 is a RANGE, not a single host (2^96 addresses)" \
    "$(inlib "$H" 127.0.0.1 '2001:db8::/32' 'printf "%s" "$(_remote_pin_class)"' | sed 's/RC=.*//')" "range"
assert_eq "IPv6 /64 is a range" \
    "$(inlib "$H" 127.0.0.1 '2001:db8::/64' 'printf "%s" "$(_remote_pin_class)"' | sed 's/RC=.*//')" "range"
m6=$(inlib "$H" 127.0.0.1 "2001:db8::/32" 'printf "%s" "$(_remote_pin_meaning)"')
assert_not_contains "…and its MEANING never claims one address" "$m6" "exactly ONE address"

m=$(inlib "$H" 127.0.0.1 "not-a-cidr" 'printf "%s" "$(_remote_pin_meaning)"')
assert_contains "…and says what it cannot state"      "$m" "cannot be stated"
assert_not_contains "…and never calls it a subnet"    "$m" "SUBNET"

# ── 11. NO recorded posture is the BASELINE, not a refusal ────────────
echo "== 11. the first run under this code warns and proceeds (no outage on upgrade)"
H=$(new_home base); put_cred "$H" delta
out=$(guard "$H" 10.9.9.9 "10.0.0.0/8")
# An EXISTING routable deployment has no posture file. Refusing there would take
# down an endpoint that is already serving — turning a warning into an outage,
# the exact failure mode this guard's scope exists to avoid. Establish the
# baseline, warn loudly, and let the NEXT run compare against something real.
assert_eq "no recorded posture → ALLOWED (baseline run)" "$(rc_of "$out")" "0"
assert_contains "…and says so"                        "$out" "BASELINE"
assert_contains "…and still names the unpinned principal" "$out" "delta"
assert_contains "…and warns the next change will refuse" "$out" "will be REFUSED"
# NEGATIVE CONTROL: the same fixture WITH a differing recorded posture refuses,
# so the allow above is the baseline arm and not a dead guard.
put_posture "$H" 'bind=loopback pin=10.0.0.0/8,127.0.0.1/32,::1/128'
out=$(guard "$H" 10.9.9.9 "10.0.0.0/8")
assert_eq "same fixture + a recorded posture → REFUSED" "$(rc_of "$out")" "1"

# ── 12. S1: the commit seam, tested BEHAVIOURALLY ─────────────────────
#
# THIS SECTION REPLACES TWO FAILED ATTEMPTS, and the history is the finding.
#
# Attempt 1 asserted, behaviourally, that a REFUSED move does not advance the
# record — three assertions that all pass identically at `27d1150`, the commit
# that HAD the bug. They exercised `_remote_posture_change_guard`, a pure
# function that never wrote the record at any commit. A guard that passes on the
# buggy commit is not a weak test, it is ZERO test, and it is worse than none
# because it occupies the slot a real one would fill and reports a green.
#
# Attempt 2 asserted the call site's POSITION, keyed on a line-continuation
# backslash and taking the first match — defeated by ADDING a second, earlier
# call site (eleven characters). The obvious repair, "…and assert there is
# exactly ONE call site", is ALSO defeatable: move that one site into the `else`
# arm and the invariant INVERTS (recorded iff NOT serving) while the count stays
# 1 and the assertion stays green. It additionally false-alarms on a reworded
# comment. Blind where it matters, noisy where it does not.
#
# The conclusion is not "write a cleverer grep". No assertion over the TEXT of
# remote-up.sh can pin this, because the property is behavioural — the posture
# file is written IFF the endpoint is serving — and it had no seam at which to
# be observed. So the fix was a CODE change: `_remote_commit_posture` takes the
# health command as an argument, and the invariant is now testable directly.
echo "== 12. the commit seam: recorded IFF serving"

# Run a commit function in a throwaway principals dir and report what happened.
# Prints "<rc> <recorded:yes|no>".
_commit_probe() {  # <lib-path> <health-cmd...>
    local lib="$1"; shift
    local d; d=$(mktemp -d "$WORK/commit.XXXXXX")
    mkdir -p "$d/.claude/principals"; chmod 700 "$d/.claude" "$d/.claude/principals"
    local rc
    rc=$(HOME="$d" MONITOR_REMOTE_PRINCIPALS_DIR="$d/.claude/principals" \
         MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=10.0.0.0/8 \
         bash -c ". '$lib'; _remote_commit_posture $*; printf '%s' \$?" 2>/dev/null)
    if [[ -f "$d/.claude/principals/posture" ]]; then printf '%s yes' "$rc"; else printf '%s no' "$rc"; fi
}

LIBREAL="$MON/_remote_lib.sh"
assert_eq "SERVING       -> rc 0, recorded"      "$(_commit_probe "$LIBREAL" /bin/true)"  "0 yes"
assert_eq "NOT serving   -> rc 2, NOT recorded"  "$(_commit_probe "$LIBREAL" /bin/false)" "2 no"
# A probe that cannot even run must read as not-serving, never as serving: an
# unrunnable check is not evidence of health.
assert_eq "probe MISSING -> rc 2, NOT recorded (fail-closed)" \
    "$(_commit_probe "$LIBREAL" /nonexistent/health-probe)" "2 no"

# ── mutant potency ────────────────────────────────────────────────────
# Every mutant that defeated a previous attempt is run against this one. A
# replacement guard that has not been shown to catch the mutants that defeated
# its predecessor has been rewritten, not tested.
MUT="$WORK/mutants"; mkdir -p "$MUT"
_mk_mutant() {  # <name> <new-body>
    python3 - "$LIBREAL" "$MUT/$1.sh" "$2" <<'PY'
import sys, re
src, dst, body = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(src).read()
new = "_remote_commit_posture() {\n" + body + "\n}\n"
t2, n = re.subn(r'_remote_commit_posture\(\) \{.*?\n\}\n', new, t, count=1, flags=re.S)
assert n == 1, "mutation did not apply"
open(dst, 'w').write(t2)
PY
}
# M-C1' — the gate removed entirely: always record.
_mk_mutant m_c1 '    _remote_record_posture || return 1
    return 0'
# M-C3' — INVERTED: record iff NOT serving. This is the one that satisfies both
# conjuncts of the count-and-position assertion while breaking the invariant.
_mk_mutant m_c3 '    "$@" >/dev/null 2>&1 && return 2
    _remote_record_posture || return 1
    return 0'
# M-C4' — the gate stubbed to true: the probe is ignored.
_mk_mutant m_c4 '    true "$@"
    _remote_record_posture || return 1
    return 0'
# M-C2' — a COMMENT reword with the code untouched. Must NOT red: a guard that
# fires on prose is noise, and noise gets silenced.
_mk_mutant m_c2 '    # (this comment was reworded; the code below is byte-identical)
    "$@" >/dev/null 2>&1 || return 2
    _remote_record_posture || return 1
    return 0'

for m in m_c1 m_c3 m_c4 m_c2; do
    # CONTROL: prove the mutation applied before concluding anything from it.
    if cmp -s "$LIBREAL" "$MUT/$m.sh"; then
        _th_fail; echo "  FAIL: mutant $m is byte-identical to the source — it did not apply"
    else
        _th_pass; echo "  PASS: mutant $m applied"
    fi
done
# The three UNSAFE mutants must each be caught by the SAME two probes above.
for m in m_c1 m_c3 m_c4; do
    serving=$(_commit_probe "$MUT/$m.sh" /bin/true)
    down=$(_commit_probe "$MUT/$m.sh" /bin/false)
    if [[ "$serving" == "0 yes" && "$down" == "2 no" ]]; then
        _th_fail; echo "  FAIL: mutant $m BREAKS the invariant but the probes stayed green"
    else
        _th_pass; echo "  PASS: mutant $m is caught (serving='$serving' down='$down')"
    fi
done
# …and the SAFE one must not.
serving=$(_commit_probe "$MUT/m_c2.sh" /bin/true)
down=$(_commit_probe "$MUT/m_c2.sh" /bin/false)
if [[ "$serving" == "0 yes" && "$down" == "2 no" ]]; then
    _th_pass; echo "  PASS: mutant m_c2 (comment reword) does NOT false-alarm"
else
    _th_fail; echo "  FAIL: mutant m_c2 reddened on a comment — the guard is noisy (serving='$serving' down='$down')"
fi

# ── the WIRING check, and it is only that ─────────────────────────────
# The seam is worthless if the production path does not use it. This is a
# TEXTUAL check; the invariant itself is pinned behaviourally by test 12.
#
# ⚠ THE PLACEMENT AXIS IS OPEN. NO COUNT ASSERTION CAN CLOSE IT, AND THIS ONE
# DOES NOT CLAIM TO. Move the seam call — do not duplicate it — onto the
# routable branch with a `/bin/true` health command, and: writer count 0, seam
# occurrences 1, every assertion in this file green, and the endpoint records
# `bind=routable pin=...` unconditionally on every routable bring-up. That is S1
# restored. There is still exactly ONE call, so counting is structurally unable
# to see it; the attack is on WHERE the call sits, not how many there are.
#
# Closing it needs test 13 to drive a ROUTABLE path, which is not currently
# possible cheaply and the cost was measured rather than guessed:
#   * the only routable-CLASS addresses available are non-local, and all three
#     reserved ranges tested (203.0.113.1, 192.0.2.1, 169.254.1.1) BLACKHOLE —
#     8s+ connect timeout each, no fast-failing option;
#   * `_remote_port_is_held` ends in an UNBOUNDED `/dev/tcp` connect with no
#     timeout knob, so a routable `cmd_up` HANGS rather than waits (measured:
#     90s and 150s caps both hit, never completing);
#   * stubbing REMOTE_SSH_BIN/REMOTE_KEYSCAN_BIN only moves the hang earlier —
#     there are at least two independent blocking probes on that path;
#   * the one address that would be fast is this host's real LAN IP, which is
#     forbidden (the live endpoint serves a real client, and a routable bind
#     previously drew a security alert).
# The enabling change is a bounded connect in `_remote_port_is_held`, filed as
# your-org/nexus-code#1028 — a production edit to a collision guard on the live
# endpoint's path, which does not belong in this commit unreviewed. Fixing #1028
# is what unblocks the routable-path test that would close the placement axis.
#
# WHAT IT DOES AND DOES NOT CLOSE — stated precisely, because an earlier
# revision called it "a fast, fallible convenience that carries no load" and the
# next promoted it to load-bearing in the same commit that left it unable to
# count. It closes: a direct writer call anywhere in the production remote
# scripts (Q3a-d, including the routable and PORT_CHANGED branches test 13 never
# traverses), a second seam call whether on its own line or sharing one, and a
# call added in a SIBLING production script. It does NOT close: THE SEAM CALL
# BEING MOVED rather than added (see the box above — the census axis and the
# placement axis are different, and only the census axis is closed here), a line
# continuation splitting the name across two lines, or variable indirection
# (`_w=_remote_record; ${_w}_posture`). Both were tried, not assumed; no
# line-based grep can see either. They are adversarial-author shapes, not
# plausible-edit shapes.
#
# COUNT OCCURRENCES, NOT LINES. `grep -c` counts matching LINES, so
# `_remote_commit_posture "$HEALTH_BIN"; _remote_commit_posture /bin/true` —
# both calls on ONE line — is a single matching line and an "exactly once"
# assertion built on `grep -c` stays GREEN. `/bin/true` always succeeds, so the
# seam records a posture for an endpoint that never served: S1 restored, with no
# comment involved, so the shell-aware strip does not close it either. Measured:
# `grep -c` says 1 on both control and bypass; `grep -o | wc -l` says 1 and 2.
_count_occurrences() {  # <name> <file...>  -> occurrences, comments dropped
    local name="$1"; shift
    grep -hv '^[[:space:]]*#' "$@" 2>/dev/null | grep -o "$name" | wc -l | tr -d ' '
}
# DROP WHOLE-LINE COMMENTS ONLY — `sed 's/#.*$//'` is NOT shell-aware. It strips
# from the first `#` regardless of quoting, so a `#` inside a STRING deletes any
# call to its right from view. That is this repo's own convention, not an
# adversarial shape: it already mutilated three live lines of remote-up.sh, and
# 49 files under monitor/ carry the `say "… #NNN …"` idiom. See #1023.
#
# POPULATION: every PRODUCTION remote script, not one hardcoded file — a port
# change IS a posture change, so remote-port-change-notify.sh is a real
# candidate for acquiring a write. THE EXCLUSIONS ARE LOAD-BEARING and are
# written here rather than left to a commit message: `monitor/_remote_lib.sh`
# holds the definition AND the in-seam call, and `monitor/watcher/test-*` holds
# fixtures that name both symbols on purpose. A naive repo-wide count is 14/11
# on a CLEAN tree — red on green code, which is how a guard gets deleted. The
# `monitor/remote-*.sh` glob excludes both by construction; that is the intent,
# not a coincidence, and it is why the glob is written this way.
_WIRING_POP=()
while IFS= read -r _f; do [[ -n "$_f" ]] && _WIRING_POP+=("$_f"); done < <(
    git -C "$REPO" ls-files -- 'monitor/remote-*.sh' 2>/dev/null | sed "s|^|$REPO/|")
# ══ POPULATION SANITY FIRST — DO NOT DELETE THIS WHEN WIDENING THE GLOB ══
# An empty enumeration makes BOTH counts 0, so `n_direct == 0` passes and the
# guard reports green having examined NOTHING. A mistyped pathspec, a `git
# ls-files` run from the wrong cwd, or a repo layout change is all it takes.
#
# This is the house's dominant failure class, and it has two named siblings:
# your-org/nexus-code#1027 (a suite that SKIPPED all four of its server-survival
# assertions and printed green, its positive control recording "this tmux does
# not crash" from a trial that never ran) and #618 (a recursive grep over an
# ignored tree returning a confident zero). In every case the tool reported
# what it could see, and what it could not see was the whole answer.
#
# So the population is asserted non-empty AND asserted to contain the one file
# it must contain. Widening the glob is welcome; removing this is not.
# `printf -v` + herestring, NOT `printf … | grep -qF`. `remote-up.sh` sorts LAST
# of the eight globbed paths today, so nothing follows the match and the hazard
# is inert — but that is a filename accident, not a property: ONE file sorting
# after it (`remote-upgrade.sh` does — `.` 0x2E < `g` 0x67) takes this to 3/800
# under load. The inverted verdict would print "wiring population is empty or
# missing remote-up.sh", i.e. this anti-#618 silent-zero guard defeated by a race.
printf -v _wiring_lines '%s\n' "${_WIRING_POP[@]}"
if (( ${#_WIRING_POP[@]} >= 2 )) && grep -qF 'remote-up.sh' <<<"$_wiring_lines"; then
    _th_pass; echo "  PASS: wiring population is non-empty (${#_WIRING_POP[@]} production remote scripts, incl. remote-up.sh)"
else
    _th_fail; echo "  FAIL: wiring population is empty or missing remote-up.sh — the counts below would be vacuous"
fi

n_direct=$(_count_occurrences '_remote_record_posture' "${_WIRING_POP[@]}")
assert_eq "no production remote script calls the writer directly" "$n_direct" "0"
n_seam=$(_count_occurrences '_remote_commit_posture' "${_WIRING_POP[@]}")
assert_eq "the seam is called EXACTLY once across the population" "$n_seam" "1"

# ── POTENCY: every bypass that has defeated a previous revision ───────
_wiring_verdict() {  # <dir-of-population-copies> -> "ok" | "caught"
    local d="$1" files=() f
    for f in "$d"/*.sh; do [[ -e "$f" ]] && files+=("$f"); done
    (( ${#files[@]} )) || { printf 'caught'; return; }   # empty = not ok
    local w s
    w=$(_count_occurrences '_remote_record_posture' "${files[@]}")
    s=$(_count_occurrences '_remote_commit_posture' "${files[@]}")
    if [[ "$w" == 0 && "$s" == 1 ]]; then printf 'ok'; else printf 'caught'; fi
}
BYP="$WORK/bypass"; rm -rf "$BYP"; mkdir -p "$BYP"
_pop_copy() {  # <name> -> a fresh copy of the whole population
    local d="$BYP/$1"; mkdir -p "$d"
    local f; for f in "${_WIRING_POP[@]}"; do cp "$f" "$d/$(basename "$f")"; done
    printf '%s' "$d"
}
_inject() {  # <dir> <file> <anchor> <line>
    python3 - "$1/$2" "$3" "$4" <<'PY2'
import sys
p, anchor, inject = sys.argv[1], sys.argv[2], sys.argv[3]
L = open(p).read().split('\n')
i = [k for k, l in enumerate(L) if anchor in l]
assert i, "anchor %r not found in %s" % (anchor, p)
L[i[0]+1:i[0]+1] = [inject]
open(p, 'w').write('\n'.join(L))
PY2
}
_replace_line() {  # <dir> <file> <match> <replacement>
    python3 - "$1/$2" "$3" "$4" <<'PY2'
import sys
p, match, repl = sys.argv[1], sys.argv[2], sys.argv[3]
L = open(p).read().split('\n')
i = [k for k, l in enumerate(L) if match in l]
assert i, "match %r not found in %s" % (match, p)
L[i[0]] = repl
open(p, 'w').write('\n'.join(L))
PY2
}

d=$(_pop_copy q3a); _inject "$d" remote-up.sh 'ensure_host_key' '    true && _remote_record_posture'
d=$(_pop_copy q3b); _inject "$d" remote-up.sh 'routable LAN — off-host' '        true && _remote_record_posture'
d=$(_pop_copy q3c); _inject "$d" remote-up.sh 'restarting the supervisor' '        true && _remote_record_posture'
d=$(_pop_copy q3d); _inject "$d" remote-up.sh 'ensure_host_key' '    _remote_record_posture || true'
d=$(_pop_copy q3e); _inject "$d" remote-up.sh 'ensure_host_key' '    _remote_commit_posture /bin/true'
# q3e1 — THE ONE-LINE DOUBLE SEAM. Invisible to `grep -c`; this is why the count
# is by occurrence.
d=$(_pop_copy q3e1); _replace_line "$d" remote-up.sh '_remote_commit_posture "$HEALTH_BIN"' \
    '    _remote_commit_posture "$HEALTH_BIN"; _remote_commit_posture /bin/true'
# hashstr — a `#` inside a string hiding the call from a naive strip.
d=$(_pop_copy hashstr); _inject "$d" remote-up.sh 'ensure_host_key' \
    '    say "see your-org/nexus-code#810"; _remote_record_posture'
# xfile — the CROSS-FILE wrapper: a sibling production script acquires a write.
# A port change IS a posture change, so this is the realistic candidate.
d=$(_pop_copy xfile); _inject "$d" remote-port-change-notify.sh 'set -uo pipefail' \
    '_pcn_record() { _remote_record_posture; }'
# seamdel — the seam call DELETED. Nothing records, ever.
d=$(_pop_copy seamdel); _replace_line "$d" remote-up.sh '_remote_commit_posture "$HEALTH_BIN"' '    : # seam call removed'
# reword — a COMMENT reworded, code untouched. Must NOT red.
d=$(_pop_copy reword); _inject "$d" remote-up.sh 'ensure_host_key' \
    '    # reworded: _remote_record_posture and _remote_commit_posture are named here'

for b in q3a q3b q3c q3d q3e q3e1 hashstr xfile seamdel; do
    if diff -rq "$BYP/$b" <(printf '') >/dev/null 2>&1; then :; fi
    # CONTROL: prove the mutation applied before concluding from it.
    if diff -r -q "$BYP/$b" "$BYP/reword" >/dev/null 2>&1; then
        _th_fail; echo "  FAIL: bypass $b did not apply (identical to the reword copy)"
    else
        _th_pass; echo "  PASS: bypass $b applied"
    fi
    if [[ "$(_wiring_verdict "$BYP/$b")" == caught ]]; then
        _th_pass; echo "  PASS: bypass $b is CAUGHT"
    else
        _th_fail; echo "  FAIL: bypass $b SLIPS THROUGH the wiring check"
    fi
done
# The SAFE case must stay green, or the guard is noise and gets silenced.
if [[ "$(_wiring_verdict "$BYP/reword")" == ok ]]; then
    _th_pass; echo "  PASS: a reworded COMMENT does not false-alarm"
else
    _th_fail; echo "  FAIL: a reworded comment reddened — the guard is noisy"
fi
# NEGATIVE CONTROL on the real tree.
d=$(_pop_copy pristine)
assert_eq "the shipped population reads clean (control)" "$(_wiring_verdict "$d")" "ok"

# ── 13. S1 end-to-end: an endpoint that never serves records NO posture ─
# The seam test above pins the decision. This drives the WHOLE of cmd_up once,
# so the seam is proved to be reached in production rather than merely correct
# in isolation. Measured discriminating: at `27d1150` this writes a record
# (RECORD WRITTEN) and at HEAD it does not.
#
# Fully hermetic, mirroring test-remote-port-select.sh: HOME, NEXUS_ROOT, the
# services registry and the principals dir all redirect into a fixture, sshd is
# a stub, and the bind is LOOPBACK on an ephemeral port. It never touches the
# live endpoint.
echo "== 13. S1 end-to-end: cmd_up on an endpoint that never comes up"
if ! command -v python3 >/dev/null 2>&1; then
    th_skip "python3 absent — cannot run the hermetic cmd_up harness"
else
UPW="$WORK/upharness"
mkdir -p "$UPW/state" "$UPW/nexusroot/monitor/.state" "$UPW/home/.claude/principals" "$UPW/stub"
chmod 700 "$UPW/home/.claude" "$UPW/home/.claude/principals"
printf 'nexus-remote-ssh\t%s\t%s\t%s\t%s\temit-only\n' \
    "$UPW/nexusroot" "$MON/remote-sshd-supervised.sh" "$MON/remote-ssh-health.sh" "$UPW/svc.log" \
    > "$UPW/services.registry"
printf '#!/usr/bin/env bash\nexit 1\n' > "$UPW/stub/sshd-dead"
chmod +x "$UPW/stub/sshd-dead"
up_kill_supervisors() {
    local pf pid
    for pf in "$UPW"/state/services/*.pid; do
        [[ -f "$pf" ]] || continue
        read -r pid < "$pf" 2>/dev/null || continue
        [[ "$pid" =~ ^[0-9]+$ ]] && { kill -TERM -- "-$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; }
        rm -f "$pf"
    done
}
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
rm -f "$UPW/home/.claude/principals/posture"
env HOME="$UPW/home" NEXUS_ROOT="$UPW/nexusroot" NEXUS_STATE_DIR="$UPW/state" \
    NEXUS_SERVICES_REGISTRY="$UPW/services.registry" \
    MONITOR_REMOTE_PRINCIPALS_DIR="$UPW/home/.claude/principals" \
    MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_PORT="$port" \
    MONITOR_REMOTE_HEALTH_REQUIRE_IDENTITY=false \
    REMOTE_SSHD_BIN="$UPW/stub/sshd-dead" REMOTE_UP_TIMEOUT=3 \
    bash "$MON/remote-up.sh" >/dev/null 2>&1
up_kill_supervisors
# CONTROL FIRST — an `assert_no_file` is trivially satisfied by a harness that
# never ran. The host key is written by ensure_host_key, which sits AFTER the
# guards and BEFORE the commit, so its presence proves cmd_up executed past the
# point where the commit decision is live. Without this the assertion below is
# the same vacuity this whole section exists to correct.
assert_file_exists "the harness actually drove cmd_up (host key was created)" \
    "$UPW/home/.claude/principals/ssh_host_ed25519_key"
assert_no_file "cmd_up on a never-serving endpoint records NO posture" \
    "$UPW/home/.claude/principals/posture"
# The SERVING end-to-end case is NOT covered here, and that is a declared
# boundary rather than an omission: making the health probe go green needs a
# REAL sshd — a banner-only stub is refused by a gate that sits BEFORE
# health_require_identity ("presented NO usable ed25519 host key"), measured,
# so no stub can produce a healthy verdict. That path belongs to the
# SLOW_TESTS=1 real-sshd tier (test-channel-integration.sh). The serving
# DECISION is covered behaviourally by test 12's `/bin/true` case.
fi

# ── 10. remote-up.sh reports the meaning on every run ─────────────────
echo "== 10. the meaning is printed by remote-up.sh, unconditionally"
if bash -c "grep -q '_remote_pin_meaning' '$MON/remote-up.sh'"; then
    _th_pass; echo "  PASS: remote-up.sh reports the pin meaning"
else
    _th_fail; echo "  FAIL: remote-up.sh does not report the pin meaning"
fi
if bash -c "grep -q '_remote_posture_change_guard' '$MON/remote-up.sh'"; then
    _th_pass; echo "  PASS: remote-up.sh runs the ordering precondition"
else
    _th_fail; echo "  FAIL: remote-up.sh does not run the ordering precondition"
fi

# ── EXACT COUNT GUARD (summary-honesty.manifest contract) ─────────────
# `th_summary_and_exit` certifies that SOMETHING was asserted and that no FAIL
# was swallowed by a subshell. It certifies NOTHING about HOW MUCH ran — so a
# whole section lost to an early `return`, a `continue`, or a skipped loop
# prints a clean green. Pin the total: a VANISHED assertion reddens.
#
# Counted from the LEDGER, not the counters: the ledger survives the subshell
# the counters die in, so it is the honest total. Update this number
# deliberately when you add or remove an assertion — that edit IS the review.
EXPECTED_ASSERTIONS=92
_ran=$(( $(_th_ledger_count P) + $(_th_ledger_count F) + $(_th_ledger_count S) ))
if [[ "$_ran" != "$EXPECTED_ASSERTIONS" ]]; then
    printf '  FAIL: ran %s assertions, expected exactly %s.\n' "$_ran" "$EXPECTED_ASSERTIONS" >&2
    printf '        A count that DROPS means assertions vanished (an early exit, a\n' >&2
    printf '        loop that did not iterate); a count that RISES means this number\n' >&2
    printf '        was not updated with the suite. Either way the green is not honest.\n' >&2
    FAIL=$(( ${FAIL:-0} + 1 ))
fi

th_summary_and_exit
