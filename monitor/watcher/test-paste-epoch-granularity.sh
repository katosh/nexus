#!/usr/bin/env bash
# The paste epoch is a KEY and a TIME, and they need different
# granularities — your-org/nexus-code#679.
#
# THE DEFECT. `paste-followup.sh` stamped `date +%s` — SECOND
# granularity — into `machine-input.tsv`, and `#676` keyed the verdict
# sidecar `.state/paste-verdicts/<window>.<epoch>` off the same value.
# Two pastes into one window within one second therefore collide: same
# TSV epoch, same sidecar name, LAST WRITER WINS. An `rc=4` (established
# non-delivery — a genuinely lost paste) followed by a same-second
# `rc=0` leaves only the `rc=0` sidecar, and the `paste-unconfirmed`
# flag is suppressed for a paste that was never delivered. Constructed
# by the `#676` skeptic as E2E-4.
#
# THE DIRECTION THAT MATTERS, and why the obvious fix is the wrong one.
# `#679` proposes `date +%s%N`. Nanoseconds do NOT survive the read
# path. The detector selects the newest row with awk (`($2 + 0) > m`,
# then prints it) and awk carries integers in a double — exact only
# below 2^53 ≈ 9.007e15. A nanosecond epoch is ~1.79e18. Measured:
#
#   1754270400123456790  --awk-->  1754270400123456768
#
# and two distinct nanosecond keys become indistinguishable. That
# printed value is what builds the sidecar path, so nanoseconds would
# make `#676`'s verdict lookup miss a file sitting right there —
# trading a rare collision for a routine silent total miss. A
# MICROSECOND epoch is ~1.79e15, exact in a double until the year 2255,
# and still bounds the collision window at 1e-6 s against a sender that
# blocks ~20 s per paste. Test B7 is the regression guard for anyone
# who later "fixes" this to the nanoseconds the issue literally asks for.
#
# THE HAZARD THE ISSUE DOES NOT NAME. The recorded value is consumed at
# TWO granularities across ELEVEN sites. Two need the RAW key (the TSV
# column, the sidecar name); the other nine compare it against a
# different clock reading — the hook stamp, the transcript's submission
# records, the window's spawn timestamp, the rendered "paste NNNs ago" —
# and every one of those is SECONDS. A raw microsecond key reaching an
# arithmetic comparison fails in the QUIET direction, which is why this
# needs assertions rather than review:
#
#   (( best < spawn_epoch ))    permanently false — the lifecycle-scope
#                               guard stops rejecting pastes from a
#                               prior life of the window name
#   (( now >= epoch ))          permanently false — the age note in the
#                               emit silently vanishes
#   machine >= prompt - slack   permanently TRUE — the attribution rule
#                               reclassifies the OPERATOR'S OWN typing
#                               as machine input, and retire-preflight
#                               reads that gate
#
# Nothing errors. The guards just stop guarding.
#
# BACKWARD COMPATIBILITY IS NOT OPTIONAL. `machine-input.tsv` is
# append-only and live: rows written before `#679` are seconds and share
# the file with microsecond rows forever. Readers normalise by
# MAGNITUDE — the two ranges are five orders of magnitude apart (a
# seconds epoch stays under 1e10 until 2286; a microseconds epoch passed
# 1e15 in 2001), so 1e13 sits in empty space between them.
#
# Run: bash monitor/watcher/test-paste-epoch-granularity.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SCRIPT="$_repo_root/monitor/paste-followup.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
ck()   { if [[ "$2" == "$3" ]]; then pass "$1 (got '$2')"; else fail "$1 — got '$2' want '$3'"; fi; }

WORK=$(mktemp -d -t nexus-679-epoch-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
# PART A — the SENDER mints a unique, microsecond-shaped key.
#
# Non-vacuity guard, same rationale as test-paste-verdict-carryforward's
# Part A: every later assertion is about a value the production sender
# writes. If the sender never writes a microsecond key, Part B would
# pass green against a format the real path never produces. So Part A
# runs the REAL script and reads the REAL ledger.
# ===========================================================================
echo "=== PART A: paste-followup.sh stamps a unique microsecond key ==="

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
            # Delimiter EXTRACTED from the requested format, never assumed.
            # Hardcoding a TAB here silently diverged from the resolver when it
            # moved off TAB (your-org/nexus-code#699: a C/POSIX locale makes
            # tmux rewrite a TAB in `-F` output, so every present window read
            # as absent). A stub that hardcodes what it claims to parse fails
            # the same way the code under test did.
            d="${fmt#*'#{window_id}'}"; d="${d%%'#{window_name}'*}"
            for w in ${MOCK_TMUX_WINDOWS:-}; do printf '@3%s%s\n' "$d" "$w"; done ;;
        *window_index*)
            # The INDEX shape (your-org/nexus-code#905).
            # `resolve_window_key` / `resolve_window_index` ask for
            # `#{window_index}<delim>#{window_name}`, which carries no
            # `window_id` — without this arm it fell through to the default
            # below and came back a BARE name with no delimiter, which the
            # resolver rightly refused as unsplittable ("Window presence is
            # UNKNOWN, not absent"), so the paste never happened. Answer it
            # the way real tmux does: index, delimiter, name — one row per
            # window, indices distinct. Delimiter EXTRACTED from the
            # requested format, never assumed, for the reason above.
            d="${fmt#*'#{window_index}'}"; d="${d%%'#{window_name}'*}"
            i=0
            for w in ${MOCK_TMUX_WINDOWS:-}; do
                printf '%s%s%s\n' "$i" "$d" "$w"; i=$(( i + 1 ))
            done ;;
        *)           printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    esac
    exit 0
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

ASTATE="$WORK/astate"; mkdir -p "$ASTATE/heartbeat"
AWIN="epochwin"
export MOCK_TMUX_WINDOWS="$AWIN"
printf '{"session_id":"%s","cwd":"/stub"}\n' "$SID" > "$ASTATE/heartbeat/$AWIN.json"

# Two pastes as fast as the shell can issue them. On the pre-#679
# sender these landed in the same second far more often than not; the
# assertion below is about the KEYS being distinct, which is the
# property, not about how fast this machine happens to be.
run_paste() {
    # NEXUS_STATE_DIR, not STATE_DIR: the sender resolves its own state
    # dir (_resolve_state_dir) and STATE_DIR is not an input. Getting
    # this wrong silently writes into the REAL ledger, which is what A0
    # exists to catch.
    NEXUS_STATE_DIR="$ASTATE" \
    PASTE_CONFIRM_BUDGET=0 \
        bash "$SCRIPT" "$AWIN" --message "follow-up $1" >/dev/null 2>&1
}
run_paste one
run_paste two

MI="$ASTATE/machine-input.tsv"
if [[ -s "$MI" ]]; then
    pass "A0 the sender wrote machine-input.tsv (non-vacuity)"
else
    fail "A0 the sender wrote NO ledger — every assertion below would be vacuous"
fi

mapfile -t A_EPOCHS < <(awk -F'\t' -v w="$AWIN" '$1 == w { print $2 }' "$MI" 2>/dev/null)
ck "A1 two pastes produced two ledger rows" "${#A_EPOCHS[@]}" "2"

# THE DEFECT ITSELF. Pre-#679 these two are equal whenever the pastes
# land in one second, and the sidecar of the first is then overwritten.
if [[ "${#A_EPOCHS[@]}" -eq 2 && "${A_EPOCHS[0]}" != "${A_EPOCHS[1]}" ]]; then
    pass "A2 the two keys are DISTINCT (the #679 collision) — ${A_EPOCHS[0]} vs ${A_EPOCHS[1]}"
else
    fail "A2 the two keys COLLIDED: ${A_EPOCHS[*]:-<none>}"
fi

# EXACTLY 16 digits, not "16 or more": a nanosecond epoch is 19 and a
# `{16,}` bound would wave it through, which is the one wrong answer
# this change exists to rule out (see B7). A microsecond epoch is 16
# digits from 2001 until the year 2286.
for e in "${A_EPOCHS[@]}"; do
    if [[ "$e" =~ ^[0-9]{16}$ ]]; then
        pass "A3 ledger epoch is microsecond-shaped, exactly 16 digits ($e)"
    else
        fail "A3 ledger epoch is not microsecond-shaped: '$e' (${#e} digits)"
    fi
done

# RESOLUTION, not just magnitude. The mint carries a fallback for a
# non-GNU `date` that scales SECONDS up to microseconds, so a key that
# degraded to second resolution still has 16 digits and still passes A3
# — it just ends in six zeros and collides exactly as before. Without
# this assertion, reverting the mint to `date +%s` reddens only the
# source-level B9 and every behavioural assertion here stays green,
# which is the "green suite that tested nothing" shape.
_hi_res=0
for e in "${A_EPOCHS[@]}"; do
    [[ "${e: -6}" == "000000" ]] || _hi_res=1
done
if (( _hi_res )); then
    pass "A3c the minted keys carry real sub-second resolution (not seconds scaled up)"
else
    fail "A3c every key ends in 000000 — the mint degraded to second resolution and collisions return"
fi

# The property behind the digit count: the key the sender ACTUALLY wrote
# must survive the reader's awk unchanged, or the sidecar lookup misses.
for e in "${A_EPOCHS[@]}"; do
    _rt=$(printf 'w\t%s\tpaste-followup\n' "$e" \
        | awk -F'\t' -v w=w '$1 == w && ($2 + 0) > m { m = $2 + 0 } END { printf "%d\n", m }')
    ck "A3b the real minted key round-trips the reader's awk" "$_rt" "$e"
done

# The #676 identity: the sidecar name must be the SAME value the TSV
# carries. Deriving it from the seconds view instead would reintroduce
# exactly the collision this change removes.
for e in "${A_EPOCHS[@]}"; do
    if [[ -e "$ASTATE/paste-verdicts/$AWIN.$e" ]]; then
        pass "A4 sidecar is keyed by the ledger epoch ($AWIN.$e)"
    else
        fail "A4 no sidecar named $AWIN.$e — sender/watcher key identity broken"
    fi
done

# Two DISTINCT sidecars is the E2E-4 property: the first verdict is no
# longer overwritten by the second.
_n_sidecars=$(find "$ASTATE/paste-verdicts" -maxdepth 1 -type f -name "$AWIN.*" 2>/dev/null | wc -l)
ck "A5 both verdicts survive (E2E-4: no last-writer-wins)" "$_n_sidecars" "2"

# ---- A6: the collision property itself, independent of timing -----------
#
# A2 above asserts the two E2E keys differ, but the sender blocks on its
# confirmation poll, so those two pastes may well land in DIFFERENT
# seconds — in which case A2 would pass against the OLD seconds-based
# mint too, and the suite would be green about a property it never
# tested. So mint repeatedly until two mints demonstrably share a
# second, and assert THOSE are distinct. That is exactly the case
# `date +%s` collided on.
_mint() {
    local k; k=$(date +%s%6N 2>/dev/null)
    [[ "$k" =~ ^[0-9]{16,}$ ]] || k=$(( $(date +%s) * 1000000 ))
    printf '%s' "$k"
}
_same_second_pair=""
for _i in $(seq 1 200); do
    _k1=$(_mint); _k2=$(_mint)
    if [[ "${_k1:0:10}" == "${_k2:0:10}" ]]; then
        _same_second_pair="$_k1 $_k2"; break
    fi
done
if [[ -z "$_same_second_pair" ]]; then
    fail "A6 could not mint two keys in one second in 200 tries — the collision case was never exercised"
else
    set -- $_same_second_pair
    if [[ "$1" != "$2" ]]; then
        pass "A6 two keys minted in the SAME second are distinct ($1 vs $2) — the #679 collision"
    else
        fail "A6 two keys minted in the same second COLLIDED: $1 == $2"
    fi
    # And the control: under the OLD seconds mint they are equal, which
    # is what makes A6 a test of the change rather than of arithmetic.
    if [[ "${1:0:10}" == "${2:0:10}" ]]; then
        pass "A6b the same pair COLLIDES at second granularity (${1:0:10}) — the defect reproduced"
    else
        fail "A6b the pair does not share a second — A6 proved nothing"
    fi
fi

# ===========================================================================
# PART B — every READER normalises, and legacy rows keep working.
# ===========================================================================
echo
echo "=== PART B: readers normalise by magnitude ==="

STATE_DIR="$WORK/bstate"; mkdir -p "$STATE_DIR"
# shellcheck source=monitor/watcher/_idle_probe.sh
source "$_repo_root/monitor/watcher/_idle_probe.sh" \
    || { echo "cannot source _idle_probe.sh" >&2; exit 1; }

if declare -F _paste_epoch_seconds >/dev/null 2>&1; then
    pass "B0 _paste_epoch_seconds is defined (non-vacuity)"
else
    fail "B0 _paste_epoch_seconds MISSING — B1-B3 would be vacuous"
fi

ck "B1 microsecond key normalises to seconds" \
   "$(_paste_epoch_seconds 1785812748574586)" "1785812748"
ck "B2 legacy seconds row passes through unchanged" \
   "$(_paste_epoch_seconds 1754270400)" "1754270400"
ck "B3 non-numeric normalises to 0, never to garbage" \
   "$(_paste_epoch_seconds 'not-an-epoch')" "0"
ck "B3b empty normalises to 0" "$(_paste_epoch_seconds '')" "0"

# ---- B4: the attribution rule must return SECONDS ------------------------
#
# The most dangerous site. `_openg_machine_input_epoch` takes a MAX
# across three sources — action-log ISO, this ledger, the spawn
# timestamp — the other two of which are seconds, and its caller asks
# `machine >= prompt_epoch - slack`. A raw microsecond value is ~1e6x
# every clock reading it is mixed with, so that test goes permanently
# true and EVERY operator submit is attributed to machine input.
BWIN="attribwin"
printf '%s\t%s\t%s\n' "$BWIN" 1785812748574586 paste-followup > "$STATE_DIR/machine-input.tsv"
_attrib=$(_openg_machine_input_epoch "$BWIN")
ck "B4 attribution rule returns SECONDS for a microsecond row" "$_attrib" "1785812748"

printf '%s\t%s\t%s\n' "$BWIN" 1754270400 paste-followup > "$STATE_DIR/machine-input.tsv"
ck "B4b attribution rule still reads a legacy seconds row" \
   "$(_openg_machine_input_epoch "$BWIN")" "1754270400"

# Mixed file: the newer microsecond row must win, normalised.
{ printf '%s\t%s\t%s\n' "$BWIN" 1754270400 paste-followup
  printf '%s\t%s\t%s\n' "$BWIN" 1785812748574586 unstick-permission
} > "$STATE_DIR/machine-input.tsv"
ck "B4c mixed legacy+microsecond ledger resolves to the newer, in seconds" \
   "$(_openg_machine_input_epoch "$BWIN")" "1785812748"

# ---- B5: retire-preflight's PROBE-LESS fallback normalises too -----------
#
# That branch is taken precisely when the probe lib is NOT loaded, so it
# cannot call _paste_epoch_seconds and carries its own normalisation.
# It gates RETIREMENT: an un-normalised value there makes every operator
# submit read as machine input, and a window the operator is actively
# using could be judged safe to retire.
# EXTRACTED from the real file, never re-typed here. A hand-copied awk
# program in a test asserts that the copy works, which stays green while
# the shipped code rots — the weaker-than-behavioural shape `#685` is
# filed about. The extraction is itself asserted (B5a) so a change to
# that block's formatting fails loudly instead of silently testing an
# empty program.
_RP_AWK=$(sed -n "/machine_epoch=\$(awk -F/,/END { print m + 0 }/p" \
    "$_repo_root/monitor/retire-preflight.sh" \
    | tail -n +2 \
    | sed "1s/^[[:space:]]*'//" \
    | sed "\$s/'[[:space:]]*\\\\*[[:space:]]*$//")
# The guard is STRUCTURAL only — "did we get a program" — and must NOT
# also require the normalisation to be present. Requiring it would make
# removing the normalisation SKIP B5b instead of reddening it: the
# assertion count would fall from 34 to 33 and the suite would report
# one failure where it should report two. An assertion that vanishes
# under a mutant is worse than one that never existed, because the
# summary still looks like it ran.
if [[ -n "${_RP_AWK//[[:space:]]/}" ]] && grep -q 'END' <<<"$_RP_AWK"; then
    pass "B5a extracted retire-preflight's real awk program (non-vacuity)"
else
    fail "B5a could not extract retire-preflight's awk — B5b below cannot run"
    _RP_AWK=""
fi
if grep -q 'if (v >= 10000000000000) v = int(v / 1000000)' \
        "$_repo_root/monitor/retire-preflight.sh"; then
    pass "B5 retire-preflight's fallback awk carries the normalisation"
else
    fail "B5 retire-preflight's fallback awk does NOT normalise — the retire gate reads a raw key"
fi
_rp_out=""
[[ -n "$_RP_AWK" ]] && _rp_out=$(awk -F'\t' -v w="$BWIN" "$_RP_AWK" \
    "$STATE_DIR/machine-input.tsv" 2>/dev/null)
ck "B5b retire-preflight's OWN awk normalises a mixed ledger" "$_rp_out" "1785812748"

# ---- B6/B7: the awk precision bound that CHOSE microseconds --------------
#
# B6 is the property the change relies on; B7 is the measurement that
# rules out the nanoseconds `#679` literally proposes. B7 failing means
# awk got wider integers and nanoseconds became viable — re-open the
# choice rather than deleting the test.
_awk_roundtrip() {
    printf 'w\t%s\tpaste-followup\n' "$1" \
        | awk -F'\t' -v w=w '$1 == w && ($2 + 0) > m { m = $2 + 0 } END { printf "%d\n", m }'
}
ck "B6 awk round-trips a MICROSECOND key exactly" \
   "$(_awk_roundtrip 1785812748574586)" "1785812748574586"
ck "B6b awk distinguishes adjacent microsecond keys" \
   "$(_awk_roundtrip 1785812748574587)" "1785812748574587"

_ns_out=$(_awk_roundtrip 1754270400123456790)
if [[ "$_ns_out" != "1754270400123456790" ]]; then
    pass "B7 awk CORRUPTS a nanosecond key ($_ns_out) — microseconds is the right granularity"
else
    fail "B7 awk now round-trips nanoseconds — the granularity choice should be re-opened, not this test deleted"
fi

# ---- B8: compaction must not corrupt a microsecond key ------------------
#
# _machine_input_prune rewrites the ledger to one max-epoch row per
# window once it passes 200 lines. A compaction that reformatted the key
# would orphan every sidecar written under the original name.
COMPACT_IN="$WORK/compact.tsv"
: > "$COMPACT_IN"
for i in $(seq 1 205); do
    printf 'filler%s\t%s\tpaste-followup\n' "$i" "$(( 1785812748574586 + i ))" >> "$COMPACT_IN"
done
printf '%s\t%s\t%s\n' "$BWIN" 1785812748574586 paste-followup >> "$COMPACT_IN"
printf '%s\t%s\t%s\n' "$BWIN" 1785812748574999 paste-followup >> "$COMPACT_IN"
_compacted=$(awk -F'\t' -v OFS='\t' \
    '$2 ~ /^[0-9]+$/ && ($2 + 0) > m[$1] { m[$1] = $2 + 0; s[$1] = $3 }
     END { for (w in m) printf "%s\t%d\t%s\n", w, m[w], s[w] }' "$COMPACT_IN" \
    | awk -F'\t' -v w="$BWIN" '$1 == w { print $2 }')
ck "B8 compaction preserves the microsecond key exactly" "$_compacted" "1785812748574999"

# ---- B9: every production writer agrees on the format -------------------
#
# Five writers append to this column (paste-followup.sh, _lib.sh's
# _machine_input_stamp and its _unstick.sh / _over_limit.sh callers,
# skeptic-channel.sh). Two units in one column of a shared append-only
# ledger is a trap for whoever widens either side — the same shape as
# the stale "consumers key on columns 1-2 only" contract `#690` had to
# correct. Assert the format at each writer's own mint site.
for _w in monitor/paste-followup.sh monitor/watcher/_lib.sh monitor/skeptic-channel.sh; do
    if grep -q 'date +%s%6N' "$_repo_root/$_w"; then
        pass "B9 $_w mints a microsecond key"
    else
        fail "B9 $_w does NOT mint a microsecond key — mixed units in one ledger column"
    fi
    if grep -q '1000000' "$_repo_root/$_w"; then
        pass "B9b $_w carries the seconds-scaled fallback for a non-GNU date"
    else
        fail "B9b $_w has no fallback — a non-GNU date would write a seconds row silently"
    fi
done

# ---------------------------------------------------------------------------
printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
exit 1
