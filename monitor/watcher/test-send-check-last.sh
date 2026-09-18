#!/usr/bin/env bash
# `ng send --check --last` / `--list`: an UNKNOWN verdict is resolvable AFTER
# THE FACT, by a caller that never captured stdout (your-org/nexus-code#1367).
#
# Run: bash monitor/watcher/test-send-check-last.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT. `ng send` returns UNKNOWN whenever the receiving pane has a turn
# in flight — the NORMAL outcome on a busy board (7 of 8 were in fact
# delivered). The only remedy, `--check --nonce <hex>`, needed a nonce that was
# printed on stdout and nowhere a caller could get it back from: a broadcast
# loop that did not capture stdout, and a `grep` that kept only the verdict
# line, both ended with an unresolvable UNKNOWN — and the issue's own author
# then RE-SENT on one, the exact move the EXCLUSIVITY RULE forbids. The
# sidecar had recorded the nonce since #1049; nothing read it back.
#
# WHAT THIS SUITE PINS. (1) the reader picks the NEWEST ng-send record and
# routes the existing --check logic through it; (2) a nonceless record (a direct
# paste-followup.sh paste) is never mistaken for an ng send; (3) `--list` is a
# complete, ordered, machine-readable inventory; (4) NOTHING here sends —
# resolving an UNKNOWN must never become a fallback. No tmux, no claude: a
# scripted adapter and a pinned submit-stamp surface.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SEND="$_repo_root/monitor/send.sh"

. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0
ck()  { assert_eq "$1" "$2" "$3"; }
ckc() { assert_contains "$1" "$2" "$3"; }
ckn() { assert_not_contains "$1" "$2" "$3"; }

WORK=$(mktemp -d -t nexus-1367-last-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
ST="$WORK/state"; HD="$WORK/harness"
W=busy3
mkdir -p "$ST/windows" "$ST/user-prompt" "$ST/paste-verdicts" "$HD"
printf '{"window":"%s","harness":"fake"}\n' "$W" > "$ST/windows/$W.json"
printf '{"window":"%s","harness":"fake"}\n' "$W.x" > "$ST/windows/$W.x.json"
for _w in nowhere busy8; do printf '{"window":"%s","harness":"fake"}\n' "$_w" > "$ST/windows/$_w.json"; done

cat > "$HD/fake.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
verb="${1:-}"; shift || true
case "$verb" in
transports) printf 't1\tshell\tsubmit-stamp\tcaller\n' ;;
liveness)   exit "${FAKE_LIVE:-0}" ;;
send)       printf 'sent %s\n' "${4:-}" >> "${FAKE_SENDLOG:?}"; exit 0 ;;
esac
exit 2
FAKE
chmod +x "$HD/fake.sh"
SENDLOG="$WORK/sent.log"; : > "$SENDLOG"; export FAKE_SENDLOG="$SENDLOG"
run() { NEXUS_STATE_DIR="$ST" NEXUS_HARNESS_DIR="$HD" bash "$SEND" "$@" 2>&1; }
run_out() { NEXUS_STATE_DIR="$ST" NEXUS_HARNESS_DIR="$HD" bash "$SEND" "$@" 2>/dev/null; }
NOW_S=$(date +%s)
pin_past()   { printf '%s\t%s\n' "$(( NOW_S - 3600 ))" "sid" > "$ST/user-prompt/$W"; }
pin_future() { printf '%s\t%s\n' "$(( NOW_S + 60 ))"   "sid" > "$ST/user-prompt/$W"; }
sent_count() { wc -l < "$SENDLOG" | tr -d ' '; }

echo '=== L0: a bare --check no longer dies about a nonce nobody gave ==='
# The old guard tested a variable that was never empty (an auto-generated nonce
# was minted first), so `--check` alone died with "no stamped send found for
# nonce <random>" — a diagnostic about a value the caller never supplied.
out0=$(run "$W" --check; echo "rc=$?")
ck  "L0 rc 1 (refused)"                                       "$(sed -n 's/^rc=//p' <<<"$out0")" "1"
ckc "L0 names --last as a remedy"                             "$out0" "--last"
ckc "L0 names --nonce as the other"                           "$out0" "--nonce"
ckn "L0 does not blame a nonce the caller never gave"         "$out0" "no stamped send found"

echo '=== L1: two ng sends; --last resolves the NEWEST and reports UNKNOWN (stamp in the past) ==='
pin_past
outA=$(run "$W" --stamp-only --transport t1 --message first)
NA=$(printf '%s\n' "$outA" | awk -F= '$1=="nonce"{print $2}')
EA=$(printf '%s\n' "$outA" | awk -F= '$1=="epoch"{print $2}')
outB=$(run "$W" --stamp-only --transport t1 --message second)
NB=$(printf '%s\n' "$outB" | awk -F= '$1=="nonce"{print $2}')
EB=$(printf '%s\n' "$outB" | awk -F= '$1=="epoch"{print $2}')
ck  "L1 fixture: two distinct nonces were recorded"           "$([[ -n "$NA" && -n "$NB" && "$NA" != "$NB" ]] && echo distinct || echo SAME)" "distinct"
ck  "L1 fixture: B is newer than A"                           "$(( EB > EA ))" "1"
out1=$(run "$W" --check --last; echo "rc=$?")
ck  "L1 rc 3 — unknown, exactly as --check --nonce would say"  "$(sed -n 's/^rc=//p' <<<"$out1")" "3"
ckc "L1 --last resolved to B's nonce"                         "$out1" "nonce=$NB"
ckn "L1 …not A's"                                             "$out1" "nonce=$NA"
ckc "L1 names the epoch it resolved"                          "$out1" "epoch=$EB"
ckc "L1 says do NOT fall back"                                "$out1" "Do NOT fall back"
ck  "L1 resolving an UNKNOWN sent NOTHING (not a fallback)"   "$(sent_count)" "0"

echo '=== L2: the SAME --last, with the receipt now present, reports delivered ==='
# One variable flips (the submit-stamp), so a reader that ignored the check
# logic and printed a fixed verdict cannot pass both L1 and L2.
pin_future
out2=$(run "$W" --check --last; echo "rc=$?")
ck  "L2 rc 0"                                                 "$(sed -n 's/^rc=//p' <<<"$out2")" "0"
ckc "L2 verdict names B's nonce"                              "$out2" "$NB"
ckc "L2 verdict token on stdout"                              "$(run_out "$W" --check --last)" "delivered"
pin_past

echo '=== L3: --list is a complete, newest-first, machine-readable inventory ==='
out3=$(run_out "$W" --list; echo "rc=$?")
ck  "L3 rc 0"                                                 "$(sed -n 's/^rc=//p' <<<"$out3")" "0"
ck  "L3 exactly two records"                                  "$(grep -c '^epoch=' <<<"$out3")" "2"
ck  "L3 the first line is the NEWEST (B)"                     "$(grep '^epoch=' <<<"$out3" | sed -n '1p' | grep -o "nonce=$NB")" "nonce=$NB"
ck  "L3 the second is A"                                      "$(grep '^epoch=' <<<"$out3" | sed -n '2p' | grep -o "nonce=$NA")" "nonce=$NA"
ckc "L3 every record names its transport"                     "$(grep '^epoch=' <<<"$out3" | grep -c 'transport=t1')" "2"
ckc "L3 carries a human-readable time"                        "$out3" "time=20"

echo '=== L4: a window with NO records — rc 1 and a reason, not an empty success ==='
out4=$(run nowhere --list; echo "rc=$?")
ck  "L4 rc 1"                                                 "$(sed -n 's/^rc=//p' <<<"$out4")" "1"
ckc "L4 says where it looked"                                 "$out4" "paste-verdicts"
out4b=$(run nowhere --check --last; echo "rc=$?")
ck  "L4b --check --last on it: rc 1"                          "$(sed -n 's/^rc=//p' <<<"$out4b")" "1"
ckc "L4b …and points at --list"                               "$out4b" "--list"

echo '=== L5: --last and --nonce are mutually exclusive ==='
out5=$(run "$W" --check --last --nonce "$NA"; echo "rc=$?")
ck  "L5 rc 1"                                                 "$(sed -n 's/^rc=//p' <<<"$out5")" "1"
ckc "L5 says so"                                              "$out5" "mutually exclusive"

echo '=== L6: a NEWER nonceless record (a direct paste-followup paste) is not mistaken for an ng send ==='
# paste-followup.sh called directly writes a sidecar with NO nonce=. --last
# must still answer about the newest ng SEND, and say a newer paste exists.
EN=$(( EB + 1000 ))
printf 'rc=3\nwindow=%s\nepoch=%s\ntransport=tmux-paste\noutcome=pasted (NOT submitted)\n' "$W" "$EN" > "$ST/paste-verdicts/$W.$EN"
out6=$(run "$W" --check --last; echo "rc=$?")
ck  "L6 still resolves B"                                     "$(grep -c "nonce=$NB" <<<"$out6")" "1"
ckc "L6 and says a NEWER record with no nonce exists"         "$out6" "NEWER record with no nonce"
ckc "L6 naming its epoch"                                     "$out6" "epoch=$EN"
out6l=$(run_out "$W" --list)
ck  "L6 --list shows all three"                               "$(grep -c '^epoch=' <<<"$out6l")" "3"
ck  "L6 the nonceless one prints nonce=-"                     "$(grep "^epoch=$EN " <<<"$out6l" | grep -c 'nonce=- ')" "1"

echo '=== L7: siblings that SHARE the prefix do not pollute the reader ==='
# `.scan` files (written by _idle_probe.sh beside the verdict) and a window
# named `<W>.x` both glob under `<W>.*`; only an all-digit tail is a record.
: > "$ST/paste-verdicts/$W.$EB.scan"
printf 'window=%s.x\nepoch=%s\nnonce=deadbeef\ntransport=t1\n' "$W" "$(( EB + 5000 ))" > "$ST/paste-verdicts/$W.x.$(( EB + 5000 ))"
out7=$(run_out "$W" --list)
ck  "L7 still exactly three records for $W"                   "$(grep -c '^epoch=' <<<"$out7")" "3"
ckn "L7 the other window's nonce is absent"                   "$out7" "deadbeef"
out7b=$(run "$W" --check --last)
ck  "L7 --last still resolves B, not the other window's newer record" "$(grep -c "nonce=$NB" <<<"$out7b")" "1"

echo '=== L8: the UNKNOWN line at send time NAMES --last, and forbids a re-send ==='
# The remedy has to be discoverable at the moment it is needed, on the line the
# caller is reading; a remedy only in --help is the discoverability gap the
# issue describes.
cat > "$HD/fake.sh" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in transports) printf 't1\tshell\tsubmit-stamp\tcaller\n';; liveness) exit 0;; send) printf 'sent\n' >> "${FAKE_SENDLOG:?}"; exit 3;; esac; exit 2
FAKE
# On its OWN window: a real send stamps a new record, which would otherwise
# displace B as the newest ng send for the mutants below.
out8=$(run busy8 --message hello; echo "rc=$?")
ck  "L8 rc 3"                                                 "$(sed -n 's/^rc=//p' <<<"$out8")" "3"
ckc "L8 names --check --last"                                 "$out8" "--check --last"
ckc "L8 says do NOT re-send"                                  "$out8" "Do NOT re-send"
ck  "L8 exactly one send happened (no retry)"                 "$(sent_count)" "1"

echo '=== M0-M2: MUTANT POTENCY ==='
MUT="$WORK/mut"; mkdir -p "$MUT"; cp "$_repo_root/monitor/_submit_evidence.sh" "$MUT/" 2>/dev/null
mutate() { local dst="$MUT/send-$1.sh"; cp "$SEND" "$dst"; [[ -n "$2" ]] && sed -i "$2" "$dst"
    if [[ -n "$2" ]] && cmp -s "$SEND" "$dst"; then assert_eq "mutant $1 APPLIED" "inert" "applied"; return 1; fi
    [[ -n "$2" ]] && assert_eq "mutant $1 APPLIED" "applied" "applied"; return 0; }
run_mut() { NEXUS_STATE_DIR="$ST" NEXUS_HARNESS_DIR="$HD" bash "$MUT/send-$1.sh" "${@:2}" 2>&1; }
mutate control ""
ck "M0 CONTROL: an unmutated copy still resolves B" "$(run_mut control "$W" --check --last | grep -c "nonce=$NB")" "1"
# M1 — oldest first: the reader would answer about a stale send.
if mutate oldest 's/-k1,1nr/-k1,1n/'; then
    ck "M1 killed: an oldest-first reader resolves A instead of B" "$(run_mut oldest "$W" --check --last | grep -c "nonce=$NA")" "1"
fi
# M2 — drop the nonce filter: a direct paste would be reported as an ng send.
if mutate nofilter 's/\$2 != "-" \&\& !done/!done/'; then
    ck "M2 killed: without the filter --last picks the nonceless paste (rc 1, no nonce to check)" \
       "$(run_mut nofilter "$W" --check --last >/dev/null 2>&1; echo $?)" "1"
fi

EXPECTED_ASSERTIONS=44
_run_total=$(( PASS + FAIL ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"
th_summary_and_exit
