#!/usr/bin/env bash
# `ng send` stamps the PRIMARY nexus's ledger, and can name the ledger's own
# coverage gap (your-org/nexus-code#1368).
#
# Run: bash monitor/watcher/test-send-ledger-primary.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT. `send.sh` rolled a private three-arm state-dir resolver whose last
# arm was `$_sd/.state` — the CLONE's own state dir when the script runs from a
# secondary clone under `<primary>/work/`. The stamp then SUCCEEDED, `die` never
# fired, the delivery went out, and the primary's `machine-input.tsv` — the one
# the watcher and every auditor read — had no row. A close on #1368 reasoned
# from the fail-loud stamp that "a delivery lacking a row did not go through
# send.sh"; this is the population that reasoning said could not exist.
#
# WHAT THIS SUITE PROVES, AND WHAT IT DOES NOT. Every send here goes through a
# PLANTED primary/clone tree under mktemp — never the live nexus — with
# NEXUS_ROOT and NEXUS_STATE_DIR both UNSET, because the defect lives in the
# arm that runs when both are absent. It runs the REAL `_resolve_state_dir`
# function text of paste-followup.sh (extracted, not copied) inside the child's
# environment, so the `stamps=self` hand-down is measured on production code
# rather than on a replica. It does not run tmux or paste-followup end to end.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SEND="$_repo_root/monitor/send.sh"
NROOT="$_repo_root/monitor/_nexus-root.sh"
PASTE="$_repo_root/monitor/paste-followup.sh"

. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0
ck()  { assert_eq "$1" "$2" "$3"; }
ckc() { assert_contains "$1" "$2" "$3"; }
ckn() { assert_not_contains "$1" "$2" "$3"; }

WORK=$(mktemp -d -t nexus-1368-ledger-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- the planted tree ------------------------------------------------------
# `nexus_primary_root` recognises a primary by `monitor/`, an executable
# `monitor/ng` and `config/`; the clone sits under `<primary>/work/`, the
# prescribed shape for watcher-touching work (CLAUDE.md "Independent clones").
P="$WORK/primary"; C="$P/work/nexus-code-task"
W=w1
mkdir -p "$P/monitor/.state/windows" "$P/config" \
         "$C/monitor/.state/windows" "$C/harness"
printf '#!/bin/sh\n' > "$P/monitor/ng"; chmod +x "$P/monitor/ng"
# BOTH state dirs know the window, so the pre-fix tree resolves an adapter and
# stamps (the defect), rather than dying for want of a descriptor.
for d in "$P" "$C"; do
    printf '{"window":"%s","harness":"fake"}\n' "$W" > "$d/monitor/.state/windows/$W.json"
done
cp "$SEND"  "$C/monitor/send.sh"
cp "$NROOT" "$C/monitor/_nexus-root.sh"

# The adapter's `send` verb evaluates paste-followup.sh's REAL resolver in the
# child environment send.sh hands it, with `_script_dir` set to the clone's
# monitor dir — exactly where the exec'd paste-followup.sh would compute it.
cat > "$C/harness/fake.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
verb="${1:-}"; shift || true
case "$verb" in
transports) printf '%s\n' "${FAKE_TRANSPORTS:-$'t1\tshell\tsubmit-stamp\tcaller'}" ;;
liveness)   exit 0 ;;
send)
    _script_dir="${FAKE_CLONE_MON:?}"
    fn=$(sed -n '/^_resolve_state_dir() {/,/^}/p' "${FAKE_PASTE:?}")
    [[ -n "$fn" ]] || { echo "EXTRACTION-EMPTY" >> "${FAKE_SENDLOG:?}"; exit 2; }
    eval "$fn"
    printf 'NEXUS_ROOT=%s\nchild-state-dir=%s\n' "${NEXUS_ROOT:-<unset>}" "$(_resolve_state_dir)" >> "${FAKE_SENDLOG:?}"
    exit 0 ;;
esac
exit 2
FAKE
chmod +x "$C/harness/fake.sh"

SENDLOG="$WORK/sent.log"
rows() { [[ -f "$1" ]] && wc -l < "$1" | tr -d ' ' || echo 0; }
reset() { rm -f "$P/monitor/.state/machine-input.tsv" "$C/monitor/.state/machine-input.tsv"
          rm -rf "$P/monitor/.state/paste-verdicts" "$C/monitor/.state/paste-verdicts"; : > "$SENDLOG"; }
# From the CLONE, with the two env seams UNSET: the arm the defect lives in.
run_clone() { (cd "$C" && env -u NEXUS_ROOT -u NEXUS_STATE_DIR \
    FAKE_SENDLOG="$SENDLOG" FAKE_CLONE_MON="$C/monitor" FAKE_PASTE="$PASTE" \
    NEXUS_HARNESS_DIR="$C/harness" bash "$C/monitor/send.sh" "$@" 2>&1); }

echo '=== P0: the extraction control — the real resolver text is non-empty and defines the function ==='
fn=$(sed -n '/^_resolve_state_dir() {/,/^}/p' "$PASTE")
ck  "P0 paste-followup.sh still defines _resolve_state_dir (else P3 measures nothing)" \
    "$(printf '%s' "$fn" | grep -c '^_resolve_state_dir() {')" "1"
ckc "P0 …and that resolver reads NEXUS_ROOT as an arm (the hand-down has something to land on)" "$fn" 'NEXUS_ROOT'

echo '=== P1: a send from a secondary clone stamps the PRIMARY ledger, not the clone'"'"'s ==='
reset
out=$(run_clone "$W" --message hi; echo "rc=$?")
ck  "P1 the send went out (rc 0 via the fake adapter)"            "$(sed -n 's/^rc=//p' <<<"$out")" "0"
ck  "P1 PRIMARY machine-input.tsv has exactly one row"           "$(rows "$P/monitor/.state/machine-input.tsv")" "1"
ck  "P1 the CLONE's machine-input.tsv has NO row"                "$(rows "$C/monitor/.state/machine-input.tsv")" "0"
ck  "P1 the row carries the guard key (column 3 = paste-followup)" \
    "$(awk -F'\t' -v w="$W" '$1==w{print $3; exit}' "$P/monitor/.state/machine-input.tsv")" "paste-followup"
ck  "P1 the sidecar landed in the PRIMARY's paste-verdicts too" \
    "$(ls "$P/monitor/.state/paste-verdicts/" 2>/dev/null | grep -c "^$W\.[0-9]*$")" "1"

echo '=== P2: the resolved primary is HANDED DOWN to the adapter'"'"'s children ==='
# paste-followup.sh (stamps=self) resolves its OWN state dir, NEXUS_ROOT second.
# Fixing send.sh's resolver alone would move the SIDECAR to the primary while
# the shipped transport still stamped the CLONE — the same defect, one process
# down. So the child must see the primary, and the REAL resolver, run in that
# environment, must answer the primary's state dir.
ck  "P2 the child saw NEXUS_ROOT = the planted primary" \
    "$(sed -n 's/^NEXUS_ROOT=//p' "$SENDLOG")" "$(cd "$P" && pwd -P)"
ck  "P2 paste-followup.sh's REAL resolver, in the child env, answers the PRIMARY's state dir" \
    "$(sed -n 's/^child-state-dir=//p' "$SENDLOG")" "$(cd "$P" && pwd -P)/monitor/.state"
ckn "P2 the extraction did not come back empty"                   "$(cat "$SENDLOG")" "EXTRACTION-EMPTY"

echo '=== P3: the resolver de-nests ON ITS OWN now (#1428) — and REFUSES without its library ==='
# This block used to be the negative control "without the hand-down the
# resolver lands on the clone", which proved P2 measured the hand-down. Since
# your-org/nexus-code#1428 paste-followup.sh's resolver goes through
# monitor/_nexus-root.sh itself, so a NEXUS_ROOT-less run from the clone ALSO
# answers the primary; the hand-down (P2) is belt, the resolver is braces. The
# control that now proves the fixture is not doing the work: remove the library
# and the resolver must REFUSE (rc 2), never fall back to any .state.
ctl=$(cd "$C" && env -u NEXUS_ROOT -u NEXUS_STATE_DIR bash -c '
    _script_dir="$1"; eval "$(sed -n "/^_resolve_state_dir() {/,/^}/p" "$2")"; _resolve_state_dir' _ "$C/monitor" "$PASTE")
ck  "P3 #1428 without the hand-down the real resolver STILL answers the primary's .state" "$ctl" "$P/monitor/.state"
mv "$C/monitor/_nexus-root.sh" "$C/monitor/_nexus-root.sh.off"
ctl_rc=$(cd "$C" && env -u NEXUS_ROOT -u NEXUS_STATE_DIR bash -c '
    _script_dir="$1"; eval "$(sed -n "/^_resolve_state_dir() {/,/^}/p" "$2")"; _resolve_state_dir >/dev/null 2>&1; echo $?' _ "$C/monitor" "$PASTE")
ck  "P3 …and with the library absent it REFUSES (rc 2) rather than guessing a .state" "$ctl_rc" "2"
mv "$C/monitor/_nexus-root.sh.off" "$C/monitor/_nexus-root.sh"

echo '=== P4: a send from the PRIMARY itself stamps its own ledger (no over-de-nesting) ==='
reset
mkdir -p "$P/harness"; cp "$C/harness/fake.sh" "$P/harness/"; cp "$SEND" "$P/monitor/send.sh"; cp "$NROOT" "$P/monitor/_nexus-root.sh"
out4=$(cd "$P" && env -u NEXUS_ROOT -u NEXUS_STATE_DIR FAKE_SENDLOG="$SENDLOG" FAKE_CLONE_MON="$P/monitor" FAKE_PASTE="$PASTE" \
       NEXUS_HARNESS_DIR="$P/harness" bash "$P/monitor/send.sh" "$W" --message hi 2>&1; echo "rc=$?")
ck  "P4 rc 0"                                                    "$(sed -n 's/^rc=//p' <<<"$out4")" "0"
ck  "P4 the primary's ledger has the row"                        "$(rows "$P/monitor/.state/machine-input.tsv")" "1"

echo '=== P5: NEXUS_STATE_DIR (the test seam) still wins, and is what children inherit ==='
reset; SD="$WORK/seam-state"; mkdir -p "$SD/windows"; cp "$P/monitor/.state/windows/$W.json" "$SD/windows/"
out5=$(cd "$C" && env -u NEXUS_ROOT NEXUS_STATE_DIR="$SD" FAKE_SENDLOG="$SENDLOG" FAKE_CLONE_MON="$C/monitor" FAKE_PASTE="$PASTE" \
       NEXUS_HARNESS_DIR="$C/harness" bash "$C/monitor/send.sh" "$W" --message hi 2>&1; echo "rc=$?")
ck  "P5 rc 0"                                                    "$(sed -n 's/^rc=//p' <<<"$out5")" "0"
ck  "P5 the row is in NEXUS_STATE_DIR"                           "$(rows "$SD/machine-input.tsv")" "1"
ck  "P5 …and in neither planted ledger"                          "$(( $(rows "$P/monitor/.state/machine-input.tsv") + $(rows "$C/monitor/.state/machine-input.tsv") ))" "0"
ck  "P5 the child's real resolver answers the seam too (arm 1 of both resolvers)" \
    "$(sed -n 's/^child-state-dir=//p' "$SENDLOG")" "$SD"

echo '=== P6: a MISSING resolver fails CLOSED — nothing stamped anywhere, the reason named ==='
reset; mv "$C/monitor/_nexus-root.sh" "$WORK/nr.aside"
out6=$(run_clone "$W" --message hi; echo "rc=$?")
ck  "P6 rc 1 (refused)"                                          "$(sed -n 's/^rc=//p' <<<"$out6")" "1"
ckc "P6 names the missing resolver"                              "$out6" "_nexus-root.sh"
ckc "P6 cites the issue"                                         "$out6" "your-org/nexus-code#1368"
ck  "P6 NO row in the primary"                                   "$(rows "$P/monitor/.state/machine-input.tsv")" "0"
ck  "P6 NO row in the clone (the old fallback did not quietly return)" "$(rows "$C/monitor/.state/machine-input.tsv")" "0"
ck  "P6 nothing was sent"                                        "$(rows "$SENDLOG")" "0"
mv "$WORK/nr.aside" "$C/monitor/_nexus-root.sh"

echo '=== C1-C3: --ledger-coverage NAMES the gap instead of reading as no-send ==='
# A Claude Code peer declares tmux-paste (shell) AND cc-sendmessage (agent). A
# delivery through the second writes no row unless the agent ran --stamp-only,
# so an auditor counting rows for this window must not read a missing row as
# "no send". The ledger's writer says so, from the same descriptor every send
# reads, and exits 3 — the tool's "you cannot conclude" code.
reset
CC=$'tmux-paste\tshell\tsubmit-stamp\tself\ncc-sendmessage\tagent\tsubmit-stamp\tcaller'
outc=$(FAKE_TRANSPORTS="$CC" run_clone "$W" --ledger-coverage; echo "rc=$?")
ck  "C1 rc 3 when an invoke=agent transport is declared"          "$(sed -n 's/^rc=//p' <<<"$outc")" "3"
ckc "C1 names the escaping transport"                            "$outc" "cc-sendmessage"
ckc "C1 says NO ROW"                                             "$outc" "NO ROW"
ckc "C1 says a missing row is not evidence"                      "$outc" "MISSING ROW IS NOT EVIDENCE"
ckc "C1 names which ledger it is talking about (the PRIMARY's)"  "$outc" "$(cd "$P" && pwd -P)/monitor/.state/machine-input.tsv"
ckc "C1 the shell transport is marked row=yes"                   "$outc" "row=yes"
ck  "C1 asking about coverage stamps NOTHING"                    "$(rows "$P/monitor/.state/machine-input.tsv")" "0"
# The NEGATIVE control the issue implies: a window whose every transport is
# shell-invocable is complete, and must NOT carry the gap clause.
outs=$(run_clone "$W" --ledger-coverage; echo "rc=$?")
ck  "C2 rc 0 when every declared transport is shell-invocable"    "$(sed -n 's/^rc=//p' <<<"$outs")" "0"
ckc "C2 says ledger-complete=yes"                                "$outs" "ledger-complete=yes"
ckn "C2 NEGATIVE CONTROL: no NO-ROW clause on a complete window" "$outs" "NO-ROW"
ckn "C2 …and no ledger-complete=no"                              "$outs" "ledger-complete=no"
# C3 — --stamp-only for the agent transport DOES land a row, which is the one
# path the coverage text says closes the gap. Both halves of the claim measured.
outt=$(FAKE_TRANSPORTS="$CC" run_clone "$W" --stamp-only --transport cc-sendmessage --message hi; echo "rc=$?")
ck  "C3 --stamp-only for the agent transport lands a PRIMARY row"  "$(rows "$P/monitor/.state/machine-input.tsv")" "1"

echo '=== M0-M2: MUTANT POTENCY ==='
MUT="$WORK/mut"; mkdir -p "$MUT"
mutate() {   # <name> <sed-expr> -> the mutant path in the CLONE's monitor dir
    local dst="$C/monitor/send-$1.sh"
    cp "$SEND" "$dst"; [[ -n "$2" ]] && sed -i "$2" "$dst"
    if [[ -n "$2" ]] && cmp -s "$SEND" "$dst"; then
        assert_eq "mutant $1 APPLIED (an inert mutant makes every verdict meaningless)" "inert" "applied"; return 1
    fi
    [[ -n "$2" ]] && assert_eq "mutant $1 APPLIED" "applied" "applied"
    return 0
}
run_mut() { (cd "$C" && env -u NEXUS_ROOT -u NEXUS_STATE_DIR \
    FAKE_SENDLOG="$SENDLOG" FAKE_CLONE_MON="$C/monitor" FAKE_PASTE="$PASTE" \
    NEXUS_HARNESS_DIR="$C/harness" bash "$C/monitor/send-$1.sh" "${@:2}" 2>&1); }
reset; mutate control ""
run_mut control "$W" --message hi >/dev/null
ck  "M0 CONTROL: an unmutated copy in the clone dir reproduces P1 (primary row)" "$(rows "$P/monitor/.state/machine-input.tsv")" "1"
# M1 — the pre-fix resolver, restored: the script-relative arm.
reset
if mutate oldarm 's|^    STATE_DIR="$NEXUS_PRIMARY/monitor/.state"|    STATE_DIR="$_sd/.state"|'; then
    run_mut oldarm "$W" --message hi >/dev/null
    ck "M1 killed: the old script-relative arm stamps the CLONE (P1 reverts)" "$(rows "$C/monitor/.state/machine-input.tsv")" "1"
    ck "M1 killed: …and the primary has nothing"                            "$(rows "$P/monitor/.state/machine-input.tsv")" "0"
fi
# M2 — resolve correctly but do NOT hand it down: the sidecar moves, the
# transport's own row would not. P2 must revert.
reset
if mutate nohand 's|^    export NEXUS_ROOT="$NEXUS_PRIMARY"|    :|'; then
    run_mut nohand "$W" --message hi >/dev/null
    # Since #1428 the child's resolver de-nests by itself, so the OBSERVABLE
    # that kills this mutant is the hand-down itself: the child saw no NEXUS_ROOT.
    ck "M2 killed: without the export the child saw NO NEXUS_ROOT (the hand-down is the mutated half)" \
       "$(sed -n 's/^NEXUS_ROOT=//p' "$SENDLOG")" "<unset>"
    ck "M2 …while send.sh's own row still went to the primary (the half a send.sh-only fix would have shipped)" \
       "$(rows "$P/monitor/.state/machine-input.tsv")" "1"
fi

# ---- the assertion COUNT, compared EXACTLY (#821 axis B) -----------------
EXPECTED_ASSERTIONS=43   # +1 at your-org/nexus-code#1428: P3 gained the library-absent refusal
_run_total=$(( PASS + FAIL ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
