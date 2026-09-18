#!/usr/bin/env bash
# The CONTENT MARKER — your-org/nexus-code#665 item 1, the half that was
# never built.
#
# WHAT WAS LEFT OPEN. Items 3 and 4 of #665's proposed fix landed: the
# detector consults the target's transcript and the emit says consumption
# "COULD NOT BE CONFIRMED" rather than asserting non-delivery. But item 1
# — "grep the transcript for the pasted content … a marker or content
# hash recorded alongside the paste record makes this exact" — did not.
# `se_submission_since` asks only whether SOME submission happened after
# the paste's epoch. That is a TEMPORAL PROXY for content identity, and
# the two come apart in the one direction that cannot be recovered from:
#
#   a paste that was genuinely LOST, in a window where the worker
#   submitted anything else afterwards, reads `yes` and is silenced.
#
# A false positive costs an investigation. A false negative is a lost
# instruction that nobody will ever look for again. So the residual is
# this issue's own defect class — a check that asserts a proxy rather
# than the property — living inside its own fix.
#
# WHAT THIS SUITE HAS TO SHOW, and the reason it exists at all: that the
# marker DISCRIMINATES. A green that only proves "a delivered paste reads
# delivered" is worthless, because the old proxy proved that too. Case D3
# is the suite: a genuinely lost paste, in a window with other traffic,
# where the proxy says `yes` and the content surface says `no`. Both are
# asserted in the same case, side by side, so the discrimination is
# measured rather than argued.
#
# MEASURED INPUTS (controlled self-paste into a live worker, 2026-08-05;
# see monitor/_submit_evidence.sh for the full record):
#   * a paste that lands mid-turn writes NO `type:"user"` record at all —
#     it writes `queue-operation`/`enqueue` carrying the bytes. The
#     detector was blind to that shape, which is a false positive it
#     manufactured on its own.
#   * the paste path is byte-transparent EXCEPT that a literal TAB
#     arrives as four spaces — flat, not tabstop-aligned (both tabstop
#     hypotheses refuted at seven tab positions, two replicates).
#
# Run: bash monitor/watcher/test-paste-content-marker.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SCRIPT="$_repo_root/monitor/paste-followup.sh"
SE_LIB="$_repo_root/monitor/_submit_evidence.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
ck()   { if [[ "$2" == "$3" ]]; then pass "$1 (got '$2')"; else fail "$1 — got '$2' want '$3'"; fi; }
ck_has() {
    if [[ -z "${3:-}" ]]; then
        fail "$(printf '%s — EMPTY needle: `grep -qF ""` matches anything, so this assertion could only have passed VACUOUSLY (your-org/nexus-code#1110). Fix the CALLER: its expected value came back empty; check the rc of whatever produced it.' "$1")"
        return
    fi
    if grep -qF -- "$3" <<<"$2"; then pass "$1"
    else fail "$(printf '%s — %q not found in %q' "$1" "$3" "$2")"; fi
}

for _dep in jq base64 sha256sum; do
    command -v "$_dep" >/dev/null 2>&1 || {
        printf 'SKIP: %s not on PATH — this suite measures a content digest and cannot fake one\n' "$_dep"
        exit 0
    }
done

WORK=$(mktemp -d -t nexus-665-marker-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Independent digest, computed WITHOUT the library under test. Using
# se_paste_digest here would make every assertion below circular: a
# canonicaliser that mangled the bytes would agree with itself.
sha_of() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

# A transcript record of each delivery spelling, content-exact.
rec_user()    { jq -cn --arg c "$1" --arg t "$2" \
                  '{type:"user",promptSource:"typed",timestamp:$t,message:{role:"user",content:$c}}'; }
rec_enqueue() { jq -cn --arg c "$1" --arg t "$2" \
                  '{type:"queue-operation",operation:"enqueue",timestamp:$t,content:$c}'; }
rec_noise()   { jq -cn --arg t "$1" \
                  '{type:"user",timestamp:$t,message:{role:"user",content:[{type:"tool_result",content:"x"}]}}'; }

# ===========================================================================
# PART A — NON-VACUITY: the real sender writes a real marker.
#
# Everything after this point reads a `digest=` line. If paste-followup.sh
# never writes one, or writes it under a key the detector does not read,
# Parts B–D would be green against a file production never produces. So
# Part A runs the REAL script and asserts the REAL path.
# ===========================================================================
echo "=== PART A: paste-followup.sh records the content marker ==="

STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
ACTIONS="$WORK/actions.log"
CC_HOME="$WORK/cc"
SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
TRANSCRIPT="$CC_HOME/projects/-stub-slug/$SID.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"
export MOCK_TRANSCRIPT="$TRANSCRIPT"

cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
cmd="${1:-}"
if [[ "$cmd" == "list-windows" ]]; then
    fmt=""; prev=""
    for a in "$@"; do [[ "$prev" == "-F" ]] && fmt="$a"; prev="$a"; done
    case "$fmt" in
        *window_id*)
            d="${fmt#*'#{window_id}'}"; d="${d%%'#{window_name}'*}"
            for w in ${MOCK_TMUX_WINDOWS:-}; do printf '@3%s%s\n' "$d" "$w"; done ;;
        *window_index*)
            # The INDEX shape (your-org/nexus-code#905): resolve_window_key /
            # resolve_window_index ask for `#{window_index}<delim>#{window_name}`,
            # which carries no `window_id`. Without this arm it fell to the
            # default below and came back a BARE, unsplittable name. Delimiter
            # EXTRACTED from the requested format, never assumed.
            d="${fmt#*'#{window_index}'}"; d="${d%%'#{window_name}'*}"
            i=0
            for w in ${MOCK_TMUX_WINDOWS:-}; do
                printf '%s%s%s\n' "$i" "$d" "$w"; i=$(( i + 1 ))
            done ;;
        *)           printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    esac
    exit 0
fi
# Capture the bytes handed to set-buffer so PART A can prove the digest
# describes what was actually pasted, not what the test hoped was.
if [[ "$cmd" == "set-buffer" && -n "${MOCK_PASTED_FILE:-}" ]]; then
    printf '%s' "${!#}" > "$MOCK_PASTED_FILE"
fi
printf '%s\n' "$*" >> "$ACTIONS"
if [[ "$cmd" == "send-keys" && "${!#}" == "Enter" \
      && "${MOCK_NO_SUBMIT:-0}" != "1" && -n "${MOCK_TRANSCRIPT:-}" ]]; then
    printf '{"type":"user","promptSource":"typed","message":{"role":"user","content":"the follow-up"}}\n' \
        >> "$MOCK_TRANSCRIPT"
fi
exit 0
STUB
chmod +x "$STUB_DIR/tmux"
export ACTIONS
export PATH="$STUB_DIR:$PATH"

WIN=testwin
export MOCK_TMUX_WINDOWS="$WIN"
export MOCK_PASTED_FILE="$WORK/pasted.bin"
RUN_STATE="$WORK/state"
mkdir -p "$RUN_STATE/heartbeat"
export NEXUS_STATE_DIR="$RUN_STATE"
export NEXUS_CC_HOME="$CC_HOME"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/ng-noop"; chmod +x "$STUB_DIR/ng-noop"
export PASTE_NG_BIN="$STUB_DIR/ng-noop"
export PASTE_CONFIRM_TIMEOUT_SECONDS=2
export PASTE_CONFIRM_POLL_SECONDS=0.1

seed_session() {
    printf '{"state":"idle_prompt","last_activity":%s,"session_id":"%s","window":"%s"}\n' \
        "$(date +%s)" "$SID" "$WIN" > "$RUN_STATE/heartbeat/$WIN.json"
    printf '{"type":"user","promptSource":"typed","message":{"role":"user","content":"the ORIGINAL spawn prompt"}}\n' \
        > "$TRANSCRIPT"
}
sidecar_for() {
    local epoch
    epoch=$(awk -F'\t' -v w="$WIN" '$1 == w && $3 ~ /^paste-followup/ { e = $2 } END { print e }' \
            "$RUN_STATE/machine-input.tsv" 2>/dev/null)
    [[ -n "$epoch" ]] || return 1
    printf '%s/paste-verdicts/%s.%s' "$RUN_STATE" "$WIN" "$epoch"
}
field_of() { awk -F= -v k="$2" '$1 == k { print $2; exit }' "$1" 2>/dev/null; }

# ---- A1: the marker exists, and describes the bytes that were pasted ------
A1_MSG='a follow-up with UTF-8 — and a ✓'
seed_session
rm -f "$RUN_STATE/machine-input.tsv" "$RUN_STATE"/paste-verdicts/* 2>/dev/null
MOCK_NO_SUBMIT=0 bash "$SCRIPT" "$WIN" --message "$A1_MSG" >/dev/null 2>&1
sc=$(sidecar_for) || sc=""
if [[ -n "$sc" && -r "$sc" ]]; then
    pass "A1 sidecar exists at the epoch-keyed path the detector reads"
else
    fail "A1 NO sidecar at the epoch-keyed path — Parts B-D would be vacuous"
fi
ck "A1 sidecar carries a digest= line matching the pasted bytes" \
   "$(field_of "$sc" digest)" "$(sha_of "$A1_MSG")"
# The digest must describe what tmux actually received, not the argument
# the test passed. These are the same string only if the sender hashes
# the message it pastes.
ck "A1 digest matches the bytes tmux was handed" \
   "$(field_of "$sc" digest)" "$(sha_of "$(cat "$MOCK_PASTED_FILE")")"
# The verdict write happens AFTER the marker write; the single-writer
# design exists so it cannot clobber it.
ck "A1 sidecar still carries the verdict alongside the marker" \
   "$(field_of "$sc" rc)" 0

# ---- A2: a TAB is hashed in its CANONICAL form ---------------------------
# The measured channel transform. Hashing the raw tab would produce a
# digest that matches nothing in any transcript — a surface that silently
# never fires, whose silence reads as "delivered".
A2_MSG=$'col\tvalue'
seed_session
rm -f "$RUN_STATE/machine-input.tsv" "$RUN_STATE"/paste-verdicts/* 2>/dev/null
MOCK_NO_SUBMIT=0 bash "$SCRIPT" "$WIN" --message "$A2_MSG" >/dev/null 2>&1
sc=$(sidecar_for) || sc=""
ck "A2 tab is hashed as four spaces (the measured channel transform)" \
   "$(field_of "$sc" digest)" "$(sha_of 'col    value')"
ck "A2 tab is NOT hashed raw" \
   "$([[ "$(field_of "$sc" digest)" == "$(sha_of "$A2_MSG")" ]] && echo raw || echo canonical)" \
   canonical

# ---- A3: the marker survives an established NON-submission --------------
# rc 4 is the true positive. The marker must be there precisely then —
# it is the case where the watcher has to decide something.
A3_MSG='this one is lost'
seed_session
rm -f "$RUN_STATE/machine-input.tsv" "$RUN_STATE"/paste-verdicts/* 2>/dev/null
MOCK_NO_SUBMIT=1 bash "$SCRIPT" "$WIN" --message "$A3_MSG" >/dev/null 2>&1
sc=$(sidecar_for) || sc=""
ck "A3 marker present on the rc=4 true-positive path" \
   "$(field_of "$sc" digest)" "$(sha_of "$A3_MSG")"
ck "A3 rc=4 still recorded" "$(field_of "$sc" rc)" 4

unset NEXUS_STATE_DIR NEXUS_CC_HOME PASTE_NG_BIN MOCK_TMUX_WINDOWS MOCK_PASTED_FILE
unset PASTE_CONFIRM_TIMEOUT_SECONDS PASTE_CONFIRM_POLL_SECONDS

# ===========================================================================
# PART B — the matcher, against real transcripts.
# ===========================================================================
printf '\n=== PART B: se_submission_with_digest reads a real transcript ===\n'

# shellcheck source=monitor/_submit_evidence.sh
source "$SE_LIB" || { echo "cannot source _submit_evidence.sh" >&2; exit 1; }

BSTATE="$WORK/bstate"; mkdir -p "$BSTATE/heartbeat"
BCC="$WORK/bcc"; BSID="bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
BT="$BCC/projects/-b-slug/$BSID.jsonl"
mkdir -p "$(dirname "$BT")"
export NEXUS_CC_HOME="$BCC"
printf '{"session_id":"%s"}\n' "$BSID" > "$BSTATE/heartbeat/bwin.json"

EPOCH=2000000000
T_BEFORE=$(iso_at $(( EPOCH - 120 )))
T_AFTER=$(iso_at  $(( EPOCH + 30 )))

MSG='please re-run the panel with the -0.25 candidate and state denominators'
DIG=$(sha_of "$MSG")
OTHER='wrapped up, report filed at reports/x.md'

# ---- B1: delivered as a type:"user" TUI submission -----------------------
{ rec_user "the spawn prompt" "$T_BEFORE"; rec_user "$MSG" "$T_AFTER"; } > "$BT"
ck "B1 delivered (user record) → yes" \
   "$(se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" yes

# ---- B2: delivered as a queue-operation/enqueue (the MEASURED shape) -----
# A paste that lands mid-turn writes only this. Answering `no` here was a
# false positive the old surface generated on its own.
{ rec_user "the spawn prompt" "$T_BEFORE"; rec_enqueue "$MSG" "$T_AFTER"; } > "$BT"
ck "B2 delivered (queued paste, enqueue record) → yes" \
   "$(se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" yes
ck "B2 the temporal surface also sees the enqueue now (queued blind spot closed)" \
   "$(se_submission_since bwin "$BSTATE" "$EPOCH")" yes

# ---- B3: THE DISCRIMINATION. Lost paste, other traffic present. ----------
# This is the case the whole issue is about, and both surfaces are
# asserted in it so the difference between them is MEASURED here, not
# claimed in a comment.
{ rec_user "the spawn prompt" "$T_BEFORE"
  rec_noise "$T_AFTER"
  rec_user "$OTHER" "$T_AFTER"; } > "$BT"
ck "B3 the OLD temporal proxy says yes — a submission did follow the paste" \
   "$(se_submission_since bwin "$BSTATE" "$EPOCH")" yes
ck "B3 the CONTENT surface says no — those bytes are in no delivery record" \
   "$(se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" no

# ---- B4: lost paste, no traffic at all ----------------------------------
{ rec_user "the spawn prompt" "$T_BEFORE"; } > "$BT"
ck "B4 lost, no other traffic → no" \
   "$(se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" no

# ---- B5: a matching record that PREDATES the paste does not vouch -------
{ rec_user "$MSG" "$T_BEFORE"; } > "$BT"
ck "B5 identical content BEFORE the paste epoch → no" \
   "$(se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" no

# ---- B6: an incomplete scan is `unknown`, NEVER `no` --------------------
# The bound is the reason `unknown` exists. Reading a truncated region and
# reporting `no` would be the same over-claim in a new place.
{ rec_user "$MSG" "$T_AFTER"; } > "$BT"
_pad=$(head -c 200000 /dev/zero | tr '\0' 'x')
printf '{"pad":"%s"}\n' "$_pad" >> "$BT"
ck "B6 transcript larger than the scan bound → unknown (not no)" \
   "$(SE_TAIL_BYTES=4096 se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" unknown

# ---- B6b: the epoch gate has two implementations; exercise BOTH ---------
# The fast path strips separators from an ISO-8601 `…Z` timestamp and
# compares 14-digit integers, so the scan costs no fork per record. A
# timestamp of any other shape falls back to `date -d`. Every other case
# in this suite uses the `…Z` form, so without these two the fallback is
# live code with no test behind it — and a broken fallback would be
# invisible until a transcript arrived in an unexpected format.
#
# The fast path's contract has TWO halves and they need different tests.
# The ANSWER half is covered here and by B5. The FORK-COUNT half — the only
# reason the change exists — was asserted by nothing, so a change that
# silently disabled the fast path would restore a fork per record with zero
# signal. B6d below counts the forks with shims. (An earlier draft argued a
# disabling mutant leaving the suite green was "correct, not a gap"; that is
# right about the answer and wrong about the contract, which is what makes
# it an untested optimisation.)
{ rec_user "$MSG" "$(date -u -d "@$(( EPOCH + 30 ))" +%Y-%m-%dT%H:%M:%S+00:00)"; } > "$BT"
ck "B6b non-Z timestamp still resolves, via the date -d fallback" \
   "$(se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" yes
{ rec_user "$MSG" "$(date -u -d "@$(( EPOCH - 300 ))" +%Y-%m-%dT%H:%M:%S+00:00)"; } > "$BT"
ck "B6b the fallback still enforces the epoch gate" \
   "$(se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" no

# ---- B6c: a per-invocation TOOL FAILURE is `unknown`, never `no` --------
# The up-front `command -v` guards catch a tool that is ABSENT. They say
# nothing about one that FAILS PER CALL — which is exactly what a fork
# returning EAGAIN looks like, i.e. the regime #655 is about. Before this,
# a stubbed-failing `base64` drove a paste that IS in the transcript to
# `no`, and the emit then rendered "…this is the shape a genuinely lost
# paste takes" having never hashed a single candidate.
#
# The trap underneath: a failed `base64` still leaves `sha256sum`
# succeeding on empty input, so the pipeline exits 0 with the digest of
# the empty string. Only `pipefail` inside the substitution catches it —
# which is why this asserts through a real failing stub rather than by
# reading the code.
{ rec_user "$MSG" "$T_AFTER"; } > "$BT"
# DECLARE the failing set per case; never mutate it incrementally.
#
# The first draft added and removed individual stubs between cases, and the
# third case inherited a failing hasher the second had installed — so it
# answered `unknown` through the hasher guard and never reached the path it
# was written for. A vacuous assertion in the unrecoverable direction, in a
# suite about checking the property rather than a proxy. The bug was not
# that one `rm -f` was missing; it was that the fixture was SHARED MUTABLE
# STATE and each case had to remember to undo the last. Rebuilding the dir
# from scratch makes the leak unrepresentable, so a future case cannot
# reintroduce it by forgetting.
FAILBIN="$WORK/failbin"
fail_only() {           # fail_only <tool>...  — exactly these fail, nothing else
    rm -rf "$FAILBIN"; mkdir -p "$FAILBIN"
    local t
    for t in "$@"; do
        printf '#!/usr/bin/env bash\nexit 1\n' > "$FAILBIN/$t"; chmod +x "$FAILBIN/$t"
    done
}
fail_only base64
ck "B6c a per-call base64 failure → unknown (not no), even though the bytes ARE there" \
   "$(PATH="$FAILBIN:$PATH" se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" unknown
fail_only sha256sum shasum
ck "B6c a per-call hasher failure → unknown (not no)" \
   "$(PATH="$FAILBIN:$PATH" se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" unknown
# The UNSAFE direction of the same defect, pinned directly rather than via
# the `degraded` flag. A failed `base64` writes nothing, and `sha256sum` on
# empty input SUCCEEDS — so without `pipefail` inside the substitution the
# pipeline exits 0 carrying the digest of the empty string. Hand the scan
# that exact digest as the thing to look for and the bug reports `yes`:
# "this paste was delivered", having decoded nothing at all. That is a
# false NEGATIVE for the detector — the unrecoverable direction — and no
# `||` on the pipeline can catch it, because the pipeline succeeded.
#
# Asserted with the empty digest as `want` because that is the only value
# that makes the failure observable; with any other digest the bug hides
# behind a mismatch.
# ONLY base64 fails here — the hasher must WORK, or this never reaches the
# decode path and answers through the hasher guard instead.
#
# `set +o pipefail` IN THE SUBSHELL, and it is the whole point of the case.
# This file runs under `set -uo pipefail`, so the AMBIENT option masks the
# library's explicit one: with pipefail on either way, deleting
# `set -o pipefail` from the library changes nothing here and the mutant
# survives. The environment the explicit option exists for is a caller that
# does NOT have it on — the watcher sources this library, and a library must
# not depend on its caller's shell options for a correctness property.
# Modelling that caller is what makes this assertion measure the mechanism
# instead of the test harness's own settings.
#
# Measured three ways under the no-pipefail mutant: leaked failing hasher →
# `unknown` (survives); fixture reset but ambient pipefail on → `unknown`
# (survives); fixture reset AND ambient pipefail off → `yes` (caught) —
# "this paste was delivered", for a paste whose bytes were never decoded.
fail_only base64
EMPTYDIG=$(printf '' | sha256sum | awk '{print $1}')
ck "B6c a failed decode must NEVER report yes via the empty-string digest" \
   "$(set +o pipefail; PATH="$FAILBIN:$PATH" se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$EMPTYDIG")" unknown
rm -rf "$FAILBIN"
# And the converse: a genuinely absent record with every tool WORKING must
# still be `no`, or the fix above would have muted the detector entirely.
{ rec_user "$OTHER" "$T_AFTER"; } > "$BT"
ck "B6c with all tools working, a genuinely absent record is still `no`" \
   "$(se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" no

# ---- B6d: the fast path's FORK COUNT, measured rather than argued -------
# `date -d` must be called at most once per SCAN (for the epoch), not once
# per RECORD. A counting shim is the only thing that can see this; the
# answer-level assertions above are blind to it by construction.
#
# Honest scope, because the commit message overstated it: this removes the
# `date` fork per candidate. `base64` and `sha256sum` still fork per
# candidate past the epoch gate, so the starvation hazard is REDUCED, not
# removed — and it is those remaining forks that B6c is about.
FORKDIR="$WORK/forkshim"; mkdir -p "$FORKDIR"
FORKLOG="$WORK/forks.txt"; : > "$FORKLOG"
real_date=$(command -v date)
cat > "$FORKDIR/date" <<SHIM
#!/usr/bin/env bash
echo date >> "$FORKLOG"
exec $real_date "\$@"
SHIM
chmod +x "$FORKDIR/date"
{ rec_user "the spawn prompt" "$T_BEFORE"
  for _i in $(seq 1 30); do rec_user "filler $_i" "$T_AFTER"; done
  rec_user "$MSG" "$T_AFTER"; } > "$BT"
: > "$FORKLOG"
PATH="$FORKDIR:$PATH" se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG" >/dev/null
n_date=$(grep -c . "$FORKLOG")
ck "B6d date is forked ONCE per scan, not once per record (31 candidates)" \
   "$(( n_date <= 2 ? 1 : 0 ))" 1
# Non-vacuity: the same fixture WITH the fast path defeated must fork far
# more, or the assertion above proves nothing about the fast path.
: > "$FORKLOG"
PATH="$FORKDIR:$PATH" SE_FORCE_DATE_FALLBACK=1 \
  se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG" >/dev/null 2>&1 || true
n_fallback=$(grep -c . "$FORKLOG")
ck "B6d …and the fallback path really does fork per record (so B6d is not vacuous)" \
   "$(( n_fallback > n_date + 10 ? 1 : 0 ))" 1
rm -rf "$FORKDIR"

# ---- B7: every unusable input degrades to unknown -----------------------
{ rec_user "$MSG" "$T_AFTER"; } > "$BT"
ck "B7 malformed digest → unknown" \
   "$(se_submission_with_digest bwin "$BSTATE" "$EPOCH" "not-a-digest")" unknown
ck "B7 unknown window (no heartbeat) → unknown" \
   "$(se_submission_with_digest nosuchwin "$BSTATE" "$EPOCH" "$DIG")" unknown

# ===========================================================================
# PART C — is the digest itself proxy-shaped?
#
# #665's residual is a check that asserts a proxy rather than the
# property, and a content hash can be made proxy-shaped too: hash the
# wrong span, match a prefix, normalise away the distinguishing bytes.
# Each case below is a mutant of the delivered content that a
# proxy-shaped matcher would accept.
# ===========================================================================
printf '\n=== PART C: the digest is not a proxy in a new costume ===\n'

c_case() {  # <label> <recorded-content> <want>
    { rec_user "$2" "$T_AFTER"; } > "$BT"
    ck "$1" "$(se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$DIG")" "$3"
}

c_case "C1 a long shared PREFIX is not a match" \
       "${MSG% denominators} something else entirely" no
c_case "C2 a one-byte difference in the MIDDLE is not a match" \
       "${MSG/-0.25/-0.26}" no
c_case "C3 a trailing-whitespace difference is not normalised away" \
       "$MSG " no
c_case "C4 truncated content is not a match" \
       "${MSG:0:40}" no
# C5 IS THE ANTI-VACUITY ASSERTION, and C1-C4 are not — a distinction the
# first version of this suite's write-up got backwards. The reference digest
# is computed by an INDEPENDENT full sha256 (`sha_of`), so any weakening of
# the matcher drives every case to `no`, which is exactly what C1-C4 want:
# they pass under every mutant. C5 is the one that reddens when the matcher
# is broken (both prefix-hash mutants). C1-C4 remain valuable as a direct
# check on the canonicalisation's blur radius; they are just not
# mutation-sensitive, and should not be cited as if they were.
c_case "C5 the exact bytes ARE a match (THIS is what makes C1-C4 meaningful)" \
       "$MSG" yes

# The channel transform, both directions: a message sent with a TAB must
# match the four spaces the transcript records, and must NOT match a
# record that kept the raw tab.
TABMSG=$'col\tvalue and more'
TABDIG=$(sha_of 'col    value and more')
c_tab() { { rec_user "$2" "$T_AFTER"; } > "$BT"
          ck "$1" "$(se_submission_with_digest bwin "$BSTATE" "$EPOCH" "$TABDIG")" "$3"; }
c_tab "C6 tab-canonical digest matches the four-space record" 'col    value and more' yes
c_tab "C7 the same digest does not match a differently-spaced record" 'col  value and more' no
# C8 exercises the READER's half of the transform, which C6 cannot: the
# record there already holds spaces, so the reader's gsub is a no-op and
# deleting it changes nothing. Found by mutation — removing the jq-side
# gsub left the suite fully green, so this branch was live code with no
# test behind it. It is the defence against a future Claude Code that
# stops expanding tabs: the sender's digest is canonical, so the reader
# has to canonicalise what it reads or every tabbed paste would go
# unmatched and fire a false positive.
c_tab "C8 a record that kept the RAW tab still matches (reader-side canonical)" \
      "$TABMSG" yes

# ===========================================================================
# PART D — the detector uses it, with the right polarity.
# ===========================================================================
printf '\n=== PART D: the detector resolves consumption by content ===\n'

STATE_DIR="$WORK/dstate"
mkdir -p "$STATE_DIR/heartbeat" "$STATE_DIR/paste-verdicts"
# shellcheck source=monitor/watcher/_idle_probe.sh
source "$_repo_root/monitor/watcher/_idle_probe.sh" \
    || { echo "cannot source _idle_probe.sh" >&2; exit 1; }

DWIN=dwin
NOW=2000000600
PRE=2000000000

printf '{"session_id":"%s"}\n' "$BSID" > "$STATE_DIR/heartbeat/$DWIN.json"
_idle_window_spawn_ts()        { printf ''; }
_openg_user_prompt_epoch()     { printf '0'; }
_paste_confirm_grace_seconds() { printf '180'; }
_machine_input_path()          { printf '%s/machine-input.tsv' "$STATE_DIR"; }
printf '%s\t%s\t%s\n' "$DWIN" "$PRE" paste-followup > "$STATE_DIR/machine-input.tsv"

# The detector resolves the transcript through ITS state dir, so point
# that window's heartbeat at the Part B transcript and reuse the fixtures.
set_marker() { printf 'window=%s\nepoch=%s\ndigest=%s\n' "$DWIN" "$PRE" "$1" \
                    > "$STATE_DIR/paste-verdicts/$DWIN.$PRE"; }
set_marker_rc() { printf 'rc=%s\nwindow=%s\nepoch=%s\ndigest=%s\n' "$1" "$DWIN" "$PRE" "$2" \
                    > "$STATE_DIR/paste-verdicts/$DWIN.$PRE"; }
clear_sidecar() { rm -f "$STATE_DIR/paste-verdicts/$DWIN".*; }

# ---- D0: baseline — a LOST paste with no marker still fires -------------
# Without this the suite could be green because the detector never fires.
{ rec_user "the spawn prompt" "$T_BEFORE"; } > "$BT"
clear_sidecar
ck "D0 baseline: no marker, nothing in the transcript → fires" \
   "$(_idle_unconfirmed_paste_epoch "$DWIN" "$NOW")" "$PRE"

# ---- D1: marker matches → suppressed ------------------------------------
{ rec_user "$MSG" "$T_AFTER"; } > "$BT"
set_marker "$DIG"
ck "D1 content marker found → suppressed" \
   "$(_idle_unconfirmed_paste_epoch "$DWIN" "$NOW")" 0
# Read from the on-disk scan record, NOT from a shell global: the call
# above runs inside `$(…)`, exactly as it does at the emit site, so a
# global would be empty in production while a same-process assertion
# passed. Asserting through the same channel the renderer uses is what
# makes this non-vacuous.
ck "D1 marker verdict recorded where the emit renderer reads it" \
   "$(_idle_paste_scan_field "$DWIN" "$PRE" verdict)" yes

# ---- D2: marker matches an ENQUEUE record → suppressed ------------------
# The #607 queued paste, now resolved POSITIVELY rather than left unknown.
{ rec_enqueue "$MSG" "$T_AFTER"; } > "$BT"
set_marker "$DIG"
ck "D2 queued paste (enqueue record) → suppressed" \
   "$(_idle_unconfirmed_paste_epoch "$DWIN" "$NOW")" 0

# ---- D3: THE RESIDUAL, CLOSED. Lost paste + other traffic → FIRES ------
# The old code suppressed this. That is the false negative #665 item 1
# names, and it is the only case in the suite whose verdict CHANGES.
{ rec_user "$OTHER" "$T_AFTER"; } > "$BT"
set_marker "$DIG"
ck "D3 other content submitted, these bytes absent → FIRES (was silenced)" \
   "$(_idle_unconfirmed_paste_epoch "$DWIN" "$NOW")" "$PRE"
ck "D3 the temporal proxy, consulted alone, would have suppressed it" \
   "$(_idle_paste_consumed "$DWIN" "$PRE")" yes
ck "D3 marker verdict recorded as no" \
   "$(_idle_paste_scan_field "$DWIN" "$PRE" verdict)" no
ck "D3 the proxy's answer is recorded beside it for the emit" \
   "$(_idle_paste_scan_field "$DWIN" "$PRE" other)" yes
ck_has "D3 the emit names what was actually established" \
   "$(_idle_paste_marker_note "$DWIN" "$PRE")" "DID submit other content"
ck_has "D3 the emit still does not assert non-delivery" \
   "$(_idle_paste_marker_note "$DWIN" "$PRE")" "appear in no delivery record"

# ---- D4: a transcript past the scan bound -------------------------------
# Two halves, because the bound has two consequences and conflating them
# is how `unknown` quietly becomes `no`.
#
# D4a: the file exceeds the bound but the matching record is inside the
# tail. A size check alone would answer `unknown` and lose a delivered
# paste to a false positive.
{ rec_user "$MSG" "$T_AFTER"; } > "$BT.head"
_pad=$(head -c 200000 /dev/zero | tr '\0' 'x')
{ printf '{"pad":"%s"}\n' "$_pad"; cat "$BT.head"; } > "$BT"
set_marker "$DIG"
ck "D4a big transcript, match inside the tail → suppressed" \
   "$(SE_TAIL_BYTES=65536 _idle_unconfirmed_paste_epoch "$DWIN" "$NOW")" 0

# D4b: the match is BEYOND the tail. The honest answer is `unknown`, the
# detector falls back, and — the part that matters — the emit must stay
# SILENT about content rather than claim the bytes are absent from a
# region it never read.
{ cat "$BT.head"; printf '{"pad":"%s"}\n' "$_pad"; } > "$BT"
set_marker "$DIG"
d4b=$(SE_TAIL_BYTES=4096 _idle_unconfirmed_paste_epoch "$DWIN" "$NOW")
ck "D4b match beyond the scan bound → unknown, so it fires (both surfaces mute)" \
   "$d4b" "$PRE"
ck "D4b the scan is recorded as unknown, never as no" \
   "$(_idle_paste_scan_field "$DWIN" "$PRE" verdict)" unknown
ck "D4b the emit makes NO content claim about a region it did not read" \
   "$(_idle_paste_marker_note "$DWIN" "$PRE")" ""

# ---- D5: no marker → behaviour is exactly as before -------------------
{ rec_user "$OTHER" "$T_AFTER"; } > "$BT"
clear_sidecar
ck "D5 no marker recorded → pre-#665 behaviour (temporal proxy suppresses)" \
   "$(_idle_unconfirmed_paste_epoch "$DWIN" "$NOW")" 0
ck "D5 no marker → the previous cycle's scan record is cleared, not left stale" \
   "$(_idle_paste_scan_field "$DWIN" "$PRE" verdict)" ""
ck "D5 no marker → no extra emit clause" "$(_idle_paste_marker_note "$DWIN" "$PRE")" ""

# ---- D6: the sender's rc=0 still suppresses (documented ordering) ------
# Not the proxy #665 indicts: a 20s observation at paste time against a
# known-current session-id. #676's argument applies unchanged.
{ rec_user "$OTHER" "$T_AFTER"; } > "$BT"
set_marker_rc 0 "$DIG"
ck "D6 sender rc=0 outranks a non-matching marker → suppressed" \
   "$(_idle_unconfirmed_paste_epoch "$DWIN" "$NOW")" 0

# ---- D7: rc=4 plus a non-matching marker → fires, both agreeing --------
set_marker_rc 4 "$DIG"
ck "D7 sender rc=4 + marker absent → fires" \
   "$(_idle_unconfirmed_paste_epoch "$DWIN" "$NOW")" "$PRE"

# ---- D8: a marker keyed to another paste is not borrowed --------------
clear_sidecar
printf 'window=%s\nepoch=%s\ndigest=%s\n' "$DWIN" "$(( PRE - 500 ))" "$DIG" \
    > "$STATE_DIR/paste-verdicts/$DWIN.$(( PRE - 500 ))"
{ rec_user "$MSG" "$T_AFTER"; } > "$BT"
ck "D8 a marker under another epoch is ignored" \
   "$(_idle_paste_marker "$DWIN" "$PRE")" ""

# ---- D9: a malformed digest line is unknown, not a suppression --------
clear_sidecar
printf 'window=%s\nepoch=%s\ndigest=%s\n' "$DWIN" "$PRE" "zzzz" \
    > "$STATE_DIR/paste-verdicts/$DWIN.$PRE"
ck "D9 malformed digest reads as absent" "$(_idle_paste_marker "$DWIN" "$PRE")" ""
{ rec_user "the spawn prompt" "$T_BEFORE"; } > "$BT"
ck "D9 malformed digest → falls back, still fires on a lost paste" \
   "$(_idle_unconfirmed_paste_epoch "$DWIN" "$NOW")" "$PRE"

# ---------------------------------------------------------------------------
printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
exit 1
