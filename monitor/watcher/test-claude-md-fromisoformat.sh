#!/usr/bin/env bash
# test-claude-md-fromisoformat.sh — execute CLAUDE.md's FROMISOFORMAT and
# ISO-PARSE-36 blocks.
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#935: two agents' probes silently
# returned a confident zero on this host, and in one case every gate answered
# `gate=clear`. Both were caught only by reconciling against a known independent
# total — the `gate=clear` instance against a known 733, which is the figure
# CLAUDE.md cites and the one measured on this PR. (An earlier revision of this
# header also quoted `0 of 339`; that number is `sk907`'s, was measured by
# nobody on this PR, and appears nowhere in CLAUDE.md — dropped rather than
# carried unattributed. your-org/nexus-code#946 F3.)
#
# WHAT IS ACTUALLY PINNED — and the distinction is the whole entry:
#
#   the CALL is LOUD      — `datetime.fromisoformat` raises AttributeError on
#                           3.6 and the interpreter exits 1. If the trap were
#                           the call, nobody would have shipped a wrong number.
#   TWO SILENCING MODES, and they are NOT the same defect:
#     mode 1 — the error is DESTROYED. A per-item
#              `try/except Exception: continue`, written to tolerate BAD ROWS
#              and reasonable for that, also swallows *no such method*. Every
#              row is attempted and discarded; the probe reports `0 of N`.
#     mode 2 — the error is PRESERVED AND NEVER CONSULTED, with NO `except`
#              anywhere. The producer fails loudly (rc 1, traceback visible),
#              its rc is never tested, the intermediate is empty, and the
#              number comes from LATER steps that each succeed on their own
#              terms. NO ROW EVER EXISTS, so the counter never increments —
#              a different shape from mode 1, needing a different remedy
#              (test the producer's rc; never consume an empty intermediate
#              as data).
#
#   An earlier revision of the entry attributed BOTH cited instances to mode 1.
#   The reviewing window measured `grep -c except` = 0 across its own
#   reproduction and still produced a confident zero, which falsified that.
#   Mode 2 is staged here FROM THAT REPRODUCTION rather than inferred, and its
#   no-`except` assertion is the falsifier kept permanent.
#   the SUBSTITUTE RUNS   — including on `git log --format=%cI` output, whose
#                           colon-bearing offset `%z` rejects on 3.6.
#
# CONTROLS:
#   A — extraction counts are PINNED. A botched extraction yielding no forms
#       satisfies every assertion by having none to make (#618's shape).
#   B — POSITIVE CONTROL: the same swallowing loop must return a NON-zero count
#       when handed a parser that works. Without it, "the loop returns 0" would
#       be satisfied by a loop that always returns 0 for any reason.
#   C — a DECOY row that is genuinely unparseable, so the substitute is shown to
#       reject bad data rather than accept everything.
#
# VERSION-CONDITIONAL ONLY WHERE THE INSTANCE REQUIRES IT (#946 F2). Two arms
# genuinely need an interpreter that LACKS the method — the mode-1 swallow
# demonstration and the mode-2 arm staged on the real `fromisoformat` producer.
# Those th_skip with a reason on >= 3.7 rather than passing vacuously, because a
# suite that silently adapts to the interpreter would itself be the defect this
# file documents. Everything else — both mode-2 SHAPE arms, the truncation arm,
# the os._exit scope arm, the substitute and both controls — is host-independent
# and runs everywhere. The distinction matters: an arm placed outside the guard
# because its claim is version-free is correct; one placed there by oversight is
# a false RED, and that is exactly what #946 F2 was.
#
# THE ASSERTIONS THAT FAIL IF THE TRAP STOPS BEING REAL — named, so a green here
# cannot be mistaken for a suite that asserts nothing. Each is listed WITH THE
# MUTATION THAT KILLS IT, because an earlier revision of this header named these
# five and said "each was confirmed to fail under mutation; see the PR report" —
# and that report exhibited ONE mutation, which killed a set overlapping these
# by only TWO members (your-org/nexus-code#946 S4). A named assertion whose
# falsifier nobody ran is exactly the unasserted surface this file is about.
#
#   "the WHOLE sequence exits 0 — a later command succeeded"
#       kill: append `; false` to the staged sequence  -> got 1 want 0
#   "…and the producer's own rc was 1 all along"
#       kill: `parse = len` + drop `.timestamp()`      -> got 0 want 1
#   "…while the intermediate it should have written is empty"
#       kill: same two-part mutation                   -> got 6 want 0
#   "mode 2 reproduction contains NO except"
#       kill: wrap the lookup in try/except            -> got 1 want 0
#   "an EMPTINESS check passes this file"
#       kill: move the bad row first, so 0 rows emit   -> got empty want non-empty
#
# NOTE the two-part mutation: `parse = len` ALONE leaves `.timestamp()` on the
# result, so the producer still dies (AttributeError on int) and the suite stays
# GREEN. An inert mutant and a real survivor print identically — that near-miss
# is why each kill above names its full edit rather than "mutate the producer".

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# ── this suite DECLARES its own population (the --population protocol) ──────
# your-org/nexus-code#1219. CLAUDE.md is the document this suite EXECUTES, so
# an edit to the fenced block it pins is exactly the edit that can change its
# verdict — and until #1219 no such edit could SELECT it: a suite that declares
# no population is INVISIBLE to `guards-for-diff` rather than excluded by it
# (#1078), appearing in neither SELECTED nor CONSIDERED AND EXCLUDED, so its
# absence reads as a considered exclusion. `gp_handle` adds this suite's own
# path and `monitor/_guard_population.sh` for free; everything else is declared
# because this suite READS ITS BYTES to reach a verdict.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"
th_claude_md_block_coverage FROMISOFORMAT ISO-PARSE-36   # the entry's UNCHECKED share, in this suite's own output (#1239)

WORK=$(mktemp -d -t nexus-fromiso-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

command -v python3 >/dev/null 2>&1 || th_abort "python3 not on PATH — cannot exercise this entry"

echo '=== Extraction: pull both delimited blocks out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

_block() {
    awk -v b="<!-- BEGIN $1 -->" -v e="<!-- END $1 -->" '
        index($0, b) { inb = 1; next }
        index($0, e) { inb = 0 }
        inb' "$CLAUDE_MD" | sed -E 's/^  //' | grep -vE '^```'
}

FI_FORMS=$(_block FROMISOFORMAT | grep -cE '^python3 ')
assert_eq "FROMISOFORMAT documents exactly 3 probes" "$FI_FORMS" "3"
if [[ "$FI_FORMS" != "3" ]]; then
    th_abort "FROMISOFORMAT block malformed — refusing to draw conclusions from it"
fi

_block ISO-PARSE-36 > "$WORK/sub.sh"
SUB_LINES=$(grep -c . "$WORK/sub.sh")
assert_eq "ISO-PARSE-36 extracted a non-empty substitute" "$( [[ "$SUB_LINES" -ge 4 ]] && echo yes || echo no )" "yes"

echo
echo '=== The interpreter, reported with its version (a claim about THIS host) ==='
PYVER=$(python3 -c 'import sys; print(sys.version.split()[0])')
echo "  python3 version: $PYVER"
HAS_FI=$(python3 -c 'import datetime; print(hasattr(datetime.datetime,"fromisoformat"))')
echo "  hasattr(datetime.datetime,\"fromisoformat\"): $HAS_FI"

echo
echo '=== The THREE documented probes are EXECUTED, not merely counted (#946 S1) ==='
# WHY THIS EXISTS. An earlier revision counted the forms (`grep -cE '^python3 '`
# = 3) and substring-matched them, then re-typed equivalents inline — and the
# report claimed the block was "executed against fixtures". That is a PROXY
# answer (readership) to a PROPERTY question (execution), which is this very
# document's dominant defect class, committed inside the suite that ships it.
# Measured by the reviewing skeptic: corrupting `"fromisoformat"` to
# `"fromisoformatX"` inside the block passed ALL 22 CLAUDE.md-reading suites,
# while the same class of corruption to PIPELINE-STATUS reddened its fixture in
# the same run. So the forms are now RUN, exactly as extracted.
FI_P1=$(_block FROMISOFORMAT | grep -E '^python3 ' | sed -n '1p')
FI_P2=$(_block FROMISOFORMAT | grep -E '^python3 ' | sed -n '2p')
FI_P3=$(_block FROMISOFORMAT | grep -E '^python3 ' | sed -n '3p')
# strip the trailing `  # comment` the document carries beside each form
FI_P1=${FI_P1%%  #*}; FI_P2=${FI_P2%%  #*}; FI_P3=${FI_P3%%  #*}

# SUBJECT IDENTITY, AND IT IS NOT A SHORTCUT — execution ALONE cannot catch this
# on the host the entry is about (your-org/nexus-code#946 S1, second round).
# Measured: corrupting `"fromisoformat"` to `"fromisoformatX"` inside the block
# left ALL 22 CLAUDE.md-reading suites GREEN even after the probes were made to
# execute, because this host's default python3 is 3.6.9 and there
#     hasattr(datetime.datetime,"fromisoformat")  -> False
#     hasattr(datetime.datetime,"fromisoformatX") -> False
# are INDISTINGUISHABLE. On 3.13.5 they are True/False and execution does catch
# it. So the runtime oracle is host-conditionally blind, and blind precisely on
# the interpreter the whole entry exists to warn about.
#
# No behavioural check can close that: on 3.6 the true name and a typo of it are
# the same observation. Only the TEXT distinguishes them. Hence execution (the
# property, discriminating on >=3.7) PLUS identity (closing the 3.6 blind spot).
# This is the opposite of the original defect — that was identity INSTEAD OF
# execution; this is identity BECAUSE execution provably cannot reach here.
assert_contains "probe 1 interrogates the attribute this entry is ABOUT" "$FI_P1" '"fromisoformat"'
assert_contains "probe 2 calls that same attribute, not a variant"       "$FI_P2" '.fromisoformat('

out_p1=$(eval "$FI_P1" 2>&1)
assert_eq "documented probe 1 RUNS and agrees with this host's hasattr" "$out_p1" "$HAS_FI"

out_p3=$(eval "$FI_P3" 2>&1)
assert_eq "documented probe 3 RUNS and reports this interpreter's version" "$out_p3" "$PYVER"

out_p2=$(eval "$FI_P2" 2>&1); rc_p2=$?
if [[ "$HAS_FI" == "True" ]]; then
    # On >=3.7 the documented call SUCCEEDS — that is the entry's own point
    # ("the call is loud" is a claim about 3.6), so assert the version-correct
    # outcome rather than skipping and losing the execution evidence.
    assert_eq "documented probe 2 RUNS; on this >=3.7 host it exits 0" "$rc_p2" "0"
else
    assert_eq       "documented probe 2 RUNS and exits 1 on this <3.7 host" "$rc_p2" "1"
    assert_contains "…naming AttributeError, from the DOCUMENTED text"      "$out_p2" "AttributeError"
fi

if [[ "$HAS_FI" == "True" ]]; then
    th_skip "silent-zero demonstration" \
            "python3 $PYVER HAS fromisoformat (>=3.7) — the #935 trap cannot be staged here; the substitute is still exercised below"
else
    echo
    echo '=== The CALL is loud: AttributeError, rc 1 ==='
    python3 -c 'import datetime; datetime.datetime.fromisoformat("2026-08-14T12:00:00")' \
        >"$WORK/loud.out" 2>&1
    rc_loud=$?
    assert_eq       "the bare call exits 1"                 "$rc_loud" "1"
    assert_contains "…naming AttributeError explicitly"     "$(cat "$WORK/loud.out")" "AttributeError"
    assert_contains "…and naming the missing attribute"     "$(cat "$WORK/loud.out")" "fromisoformat"

    echo
    echo '=== The IDIOM is silent: a per-item except turns it into a plausible ZERO ==='
    cat > "$WORK/probe.py" <<'PYEOF'
import datetime
rows = ["2026-08-14T12:00:00", "2026-08-14T13:00:00", "2026-08-14T14:00:00"]
n = 0
for r in rows:
    try:
        datetime.datetime.fromisoformat(r)
        n += 1
    except Exception:
        continue
print("parsed %d of %d" % (n, len(rows)))
PYEOF
    python3 -u "$WORK/probe.py" >"$WORK/probe.out" 2>&1
    rc_probe=$?
    assert_eq       "the swallowing probe EXITS 0 — the defect is that it succeeds" "$rc_probe" "0"
    assert_contains "…while reporting a confident, plausible ZERO"                  "$(cat "$WORK/probe.out")" "parsed 0 of 3"
    assert_not_contains "…and never mentions the real cause"                        "$(cat "$WORK/probe.out")" "AttributeError"
fi

echo
echo '=== MODE 2: the error is PRESERVED and never consulted — no `except` anywhere ==='
# your-org/nexus-code#926, staged from the reviewing window's own reproduction
# rather than inferred. The entry previously attributed BOTH cited instances to
# a swallowing `except`; that window measured `grep -c except` = 0 across its
# whole reproduction and still produced a confident zero. This arm exists so
# that claim cannot silently rot back to the single-mode version.
#
# Shape: the producer fails LOUDLY (rc 1, traceback on stderr — NOT redirected,
# because in the real instance it was visible and simply irrelevant). Its rc is
# never tested. The intermediate is empty. The number then comes from LATER
# steps that each succeed on their own terms, and the overall rc is 0.
#
# HOST-INDEPENDENT BY CONSTRUCTION (your-org/nexus-code#946 F2). This arm used
# to be staged on `fromisoformat` ITSELF, which made it require the interpreter
# to LACK the method — while the version guard above covers only the mode-1 arm.
# Result: 5 assertions failed, rc 1, on every host with Python >= 3.7 (measured
# 3.9.18 / 3.11.6 / 3.13.5 identically red, 3.6.9 green), i.e. a false RED in a
# corpus every operator clones. The arm's claim is "the producer's rc is never
# tested", NOT "3.6 lacks fromisoformat", so decoupling it from the interpreter
# version keeps the coverage on EVERY host instead of discarding it on most.
# The real cited instance is still exercised, in its own arm below.
M2="$WORK/mode2"; mkdir -p "$M2"
cat > "$M2/gen.py" <<'PYEOF'
import datetime, sys
# `no_such_parser` has never existed on ANY CPython, so this raises the same
# AttributeError on every version — the identical shape `fromisoformat` has on
# 3.6.9, with no dependence on the host's interpreter. The lookup happens
# before stdin is read, so NO ROW EVER EXISTS: mode 2's defining symptom.
parse = datetime.datetime.no_such_parser
for line in sys.stdin:
    print(parse(line.strip()).timestamp())
PYEOF
printf '2026-08-14T12:00:00\n2026-08-14T13:00:00\n' > "$M2/rows.txt"

# PRECONDITION CONTROL: the staged attribute really is absent HERE. Without
# this the arm's premise is assumed rather than measured on the running host.
m2_absent=$(python3 -c 'import datetime; print(hasattr(datetime.datetime,"no_such_parser"))')
assert_eq "the staged attribute is absent on THIS interpreter, whatever its version" "$m2_absent" "False"

# THE witnessing assertion: this mode needs no swallow at all.
m2_except=$(grep -c 'except' "$M2/gen.py" || true)
assert_eq "mode 2 reproduction contains NO except (grep -c) — the falsifier" "$m2_except" "0"

m2_out=$(cd "$M2" && bash -c '
    python3 gen.py < rows.txt > parsed.tsv 2>stderr.log
    echo "rows parsed: $(wc -l < parsed.tsv)"
    n=0; while IFS= read -r x; do n=$((n+1)); done < parsed.tsv
    echo "ledger entries: $n"
    echo "gate: clear"
'); m2_rc=$?

assert_eq       "the WHOLE sequence exits 0 — a later command succeeded"  "$m2_rc" "0"
assert_contains "…reporting a well-formed zero for rows"                  "$m2_out" "rows parsed: 0"
assert_contains "…and a well-formed zero for the ledger"                  "$m2_out" "ledger entries: 0"
assert_contains "…and a clean-looking verdict as the LAST line"           "$m2_out" "gate: clear"

# The error was never destroyed — it is right there, preserved and unconsulted.
assert_contains "the AttributeError was PRESERVED, not swallowed" "$(cat "$M2/stderr.log")" "AttributeError"
m2_py_rc=$(cd "$M2" && { python3 gen.py < rows.txt > /dev/null 2>&1; echo $?; })
assert_eq "…and the producer's own rc was 1 all along, simply not tested" "$m2_py_rc" "1"
assert_eq "…while the intermediate it should have written is empty"       \
          "$(wc -c < "$M2/parsed.tsv" | tr -d ' ')" "0"

echo
echo '=== MODE 2 on the REAL cited producer — stageable only where fromisoformat is absent ==='
# The arm above proves the SHAPE on any interpreter. This one proves the shape
# is faithful to the instance #935 actually cites, by running the identical
# sequence with the real `fromisoformat` call. It can only be staged on <3.7,
# so it th_skip's with a reason elsewhere — the skip loses the INSTANCE, never
# the shape, which is the whole point of splitting the two.
if [[ "$HAS_FI" == "True" ]]; then
    th_skip "mode 2 on the real fromisoformat producer" \
            "python3 $PYVER HAS fromisoformat (>=3.7) — the CITED producer cannot fail here; the mode-2 SHAPE is covered above on a host-independent producer, so this skip costs the instance and not the coverage"
else
    R2="$WORK/mode2real"; mkdir -p "$R2"
    cat > "$R2/gen.py" <<'PYEOF'
import datetime, sys
for line in sys.stdin:
    print(datetime.datetime.fromisoformat(line.strip()).timestamp())
PYEOF
    cp "$M2/rows.txt" "$R2/rows.txt"
    r2_out=$(cd "$R2" && bash -c '
        python3 gen.py < rows.txt > parsed.tsv 2>stderr.log
        echo "rows parsed: $(wc -l < parsed.tsv)"
        echo "gate: clear"
    '); r2_rc=$?
    assert_eq       "the real fromisoformat producer reproduces mode 2: whole sequence exits 0" "$r2_rc" "0"
    assert_contains "…with the same well-formed zero"        "$r2_out" "rows parsed: 0"
    assert_contains "…and the same clean-looking verdict"    "$r2_out" "gate: clear"
    assert_contains "…and the same PRESERVED AttributeError" "$(cat "$R2/stderr.log")" "fromisoformat"
    r2_py_rc=$(cd "$R2" && { python3 gen.py < rows.txt > /dev/null 2>&1; echo $?; })
    assert_eq "…and the same untested producer rc of 1" "$r2_py_rc" "1"
fi

echo
echo '=== MODE 2, general symptom: TRUNCATED at the point of failure, not zero ==='
# The zero above is specific to a MISSING METHOD, which fails before any data
# is read. A DATA-dependent failure partway through leaves a SHORT, plausible
# count instead — which is worse, because a zero is at least suspicious. This
# arm exists because the entry now claims that, and a claim with no fixture is
# the defect one layer up (#940).
T2="$WORK/trunc"; mkdir -p "$T2"
cat > "$T2/gen.py" <<'PYEOF'
import sys
for line in sys.stdin:
    s = line.strip()
    print(int(s))          # dies on the first non-integer row
PYEOF
printf '1\n2\nnot-a-number\n4\n5\n' > "$T2/rows.txt"

trunc_out=$(cd "$T2" && bash -c '
    python3 gen.py < rows.txt > parsed.tsv 2>stderr.log
    n=0; while IFS= read -r x; do n=$((n+1)); done < parsed.tsv
    echo "ledger entries: $n"
    echo "gate: clear"
'); trunc_rc=$?

assert_eq       "the whole sequence still exits 0"                    "$trunc_rc" "0"
assert_contains "…and reports a SHORT count, not a zero"              "$trunc_out" "ledger entries: 2"
assert_contains "…with the same clean-looking verdict"                "$trunc_out" "gate: clear"
assert_eq "the intermediate is TRUNCATED at the failure, not empty" \
          "$(grep -c . "$T2/parsed.tsv")" "2"
trunc_py_rc=$(cd "$T2" && { python3 gen.py < rows.txt > /dev/null 2>&1; echo $?; })
assert_eq "…while the producer's own rc was 1" "$trunc_py_rc" "1"

# THE consequence for the remedy: an emptiness check does NOT catch this.
assert_eq "an EMPTINESS check passes this file — so it is not the remedy that generalises" \
          "$( [[ -s "$T2/parsed.tsv" ]] && echo non-empty || echo empty )" "non-empty"

# Buffering does not turn the partial into a zero: on an UNHANDLED EXCEPTION
# CPython runs interpreter finalization, which flushes sys.stdout.
#
# (Yes — this next line is a pipeline whose exit status is `grep -c`'s, in the
# suite that ships the entry about exactly that. It is correct here: the COUNT
# is the value wanted, the status is not read by anything, and `grep -c`
# returning 1 on no-match would still print the 0 we would then assert on. The
# entry's rule is "when a status matters, drop the pipe" — here it does not.)
cp "$T2/rows.txt" "$T2/rows2.txt"
unbuf=$(cd "$T2" && { python3 -u gen.py < rows2.txt 2>/dev/null | grep -c . ; })
assert_eq "python3 -u yields the same 2 rows — buffering is not the mechanism" "$unbuf" "2"

# SCOPE THE ABOVE, so nobody generalises it to "a dying producer leaves its
# rows behind". That is true of an unhandled exception and FALSE of a hard
# exit: os._exit bypasses finalization, so the flush never happens and the
# intermediate is EMPTY — same unconsulted rc, and now indistinguishable from
# the zero case. Measured rather than asserted, because the scope caveat is
# the kind of thing that rots into a false general rule.
cat > "$T2/hard.py" <<'PYEOF'
import os, sys
sys.stdout.write("row0\n")
sys.stdout.write("row1\n")
os._exit(1)                # bypasses interpreter finalization — NO flush
PYEOF
hard_rows=$(cd "$T2" && { python3 hard.py > hard.tsv 2>/dev/null; grep -c . hard.tsv || true; })
assert_eq "os._exit bypasses the flush — 0 rows, NOT the 2 an exception leaves" "$hard_rows" "0"
hard_rc=$(cd "$T2" && { python3 hard.py > /dev/null 2>&1; echo $?; })
assert_eq "…while its rc is still 1, still unconsulted"                        "$hard_rc" "1"

echo
echo '=== CONTROL B: the SAME swallowing loop returns non-zero with a working parser ==='
# Without this, "the loop returns 0" proves nothing — a loop that always
# returned 0 would satisfy it. Here only the parser changes.
cat > "$WORK/probe_ok.py" <<'PYEOF'
import datetime
rows = ["2026-08-14T12:00:00", "2026-08-14T13:00:00", "2026-08-14T14:00:00"]
n = 0
for r in rows:
    try:
        datetime.datetime.strptime(r, "%Y-%m-%dT%H:%M:%S")
        n += 1
    except Exception:
        continue
print("parsed %d of %d" % (n, len(rows)))
PYEOF
python3 -u "$WORK/probe_ok.py" >"$WORK/probe_ok.out" 2>&1
assert_contains "same loop, working parser → parsed 3 of 3" "$(cat "$WORK/probe_ok.out")" "parsed 3 of 3"

echo
echo '=== The documented substitute RUNS, verbatim from the block ==='
bash "$WORK/sub.sh" >"$WORK/sub.out" 2>&1
rc_sub=$?
assert_eq       "the documented substitute exits 0"              "$rc_sub" "0"
assert_contains "…and parses the colon-offset form git emits"    "$(cat "$WORK/sub.out")" "2026-08-14 10:18:41-07:00"

echo
echo '=== …and on a REAL git timestamp from this repo, not a literal ==='
TS=$(git -C "$REPO_ROOT" log -1 --format=%cI)
assert_contains "git --format=%cI emits a COLON-bearing offset" "$TS" ":"
PARSED=$(python3 -c '
import datetime, re, sys
s = sys.argv[1].strip()
if s.endswith("Z"): s = s[:-1] + "+0000"
s = re.sub(r"([+-]\d{2}):(\d{2})$", r"\1\2", s)
print(datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S%z"))' "$TS")
PARSE_RC=$?
# COMPARE LIKE WITH LIKE, IN ONE FRAME (your-org/nexus-code#1256).
# `strptime`/`%z` renders in the timestamp's ORIGINAL offset; `date -d` renders
# in the RUNNER's local timezone. Both are correct; the COMPARISON was not.
# Across the UTC midnight boundary they name different DAYS, so the old
# `$(date -d "$TS" +%Y-%m-%d)` needle made this assertion a function of the WALL
# CLOCK rather than of the tree: on a UTC-clocked runner it reddened for every
# commit whose committer time fell between 17:00 and 24:00 Pacific — measured on
# CI at head `6b91621`, and reproduced here with the tree held byte-identical
# and only the commit timestamp varied (18:17 Pacific FAIL / 07:00 PASS).
#
# The needle comes from a FUNCTION so that its timezone-invariance can be
# ASSERTED rather than assumed. Keying on the PROPERTY — one frame, one day, in
# every runner timezone — not on this line's SHAPE, which is what an "is there a
# `date -d` here?" lint would do and would pass the moment somebody spelled the
# same mistake differently.
_head_day() { printf '%s\n' "${TS%%T*}"; }   # git's own offset: the frame strptime preserves
TS_DAY=$(_head_day)
# An EMPTY needle is contained by every string, so a malformed $TS would turn
# this assertion into a permissive pass. Refuse it loudly instead of asserting
# nothing — validate the SHAPE, never merely non-emptiness.
[[ "$TS_DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    || th_abort "git --format=%cI yielded no ISO day to compare against: '$TS'"
# THE ERROR MUST NOT BE ABLE TO SATISFY THE ASSERTION (your-org/nexus-code#1304).
# This assertion was REPAIRED once, for `#1256`, and the repair is what made it
# vacuous — which is the hard case, because a fix carries a presumption of
# improvement and "the red went away" is equally consistent with FIXED and with
# STOPPED ASKING.
#
# Two enabling defects, both now closed:
#   * `2>&1` folded the traceback into $PARSED, and a ValueError ECHOES ITS INPUT —
#       ValueError: time data '2026-09-02T04:14:07-0700' does not match format '…'
#     so the failure message CONTAINED $TS_DAY. A diagnostic is not a value.
#   * the needle was a PREFIX of the haystack, so `assert_contains` could not fail
#     on any string that merely quotes the input.
#
# PROVEN BY MUTANT, NOT BY READING: with the format string corrupted so the parse
# CANNOT succeed, this suite reported `47 passed, 0 failed` at rc 0 and this very
# line said PASS. A read would have argued it; only the mutant settled it.
#
# The rc is read on the line immediately after the assignment — anything that
# executes in between is a write to `$?` (`#1202`) — and a failed parse is now a
# red on its OWN terms rather than something the day comparison has to catch.
assert_eq "the substitute EXITS 0 on this repo's own HEAD timestamp" "$PARSE_RC" "0"
# EQUALITY, not containment. `${PARSED%% *}` is the rendering's day field; requiring
# it to EQUAL $TS_DAY is falsifiable, where containment of a prefix is not. This is
# the same rule the block above already applies to $TS_DAY itself — validate the
# SHAPE, never merely that something was found — applied one line further down.
assert_eq "the substitute parses this repo's own HEAD timestamp to the SAME day" "${PARSED%% *}" "$TS_DAY"

# ---- the falsifier kept permanent: this needle is TZ-INVARIANT --------------
# Both arms are deterministic: the live one varies ONLY the timezone (the axis
# the defect lived on) while holding $TS fixed, and the positive control pins a
# FIXED timestamp — a guard against a clock bug must not itself be
# clock-dependent. `_1256_TS` is the exact CI-red timestamp from `#1256`.
_1256_TS='2026-08-31T18:17:18-07:00'
_head_day_1256_broken() { TZ_UNUSED= date -d "$_1256_TS" +%Y-%m-%d 2>/dev/null; }
_1256_zones='UTC America/Los_Angeles Australia/Sydney'

_1256_broken_days=$(for _tz in $_1256_zones; do ( export TZ="$_tz"; _head_day_1256_broken ); done | sort -u | wc -l)
assert_eq "positive control: the OLD \`date -d\` needle names MORE THAN ONE day across runner timezones" \
    "$( [[ "$_1256_broken_days" -gt 1 ]] && echo yes || echo no )" "yes"

_1256_live_days=$(for _tz in $_1256_zones; do ( export TZ="$_tz"; _head_day ); done | sort -u | wc -l)
assert_eq "…while the needle actually used names exactly ONE day in every runner timezone" \
    "$_1256_live_days" "1"

echo
echo '=== CONTROL C: the substitute REJECTS genuinely bad data ==='
BAD=$(python3 -c '
import datetime, re, sys
s = "not-a-timestamp"
try:
    s2 = re.sub(r"([+-]\d{2}):(\d{2})$", r"\1\2", s)
    datetime.datetime.strptime(s2, "%Y-%m-%dT%H:%M:%S%z")
    print("ACCEPTED")
except ValueError:
    print("REJECTED")' 2>&1)
assert_eq "a decoy row is rejected, so the parser is not accept-everything" "$BAD" "REJECTED"

# ---- assertion-count guard (your-org/nexus-code#946 F6) -------------------
# A missing assert_* helper (a typo → rc 127) is counted by NOTHING: the suite
# still prints ALL TESTS PASSED with a quietly smaller total. Pin against the
# configuration ACTUALLY DETECTED, never a single magic number — an
# unconditional pin would go red on every >= 3.7 host, which is the exact false
# RED this PR's F2 fix removed, re-introduced one layer up.
#   host-independent arms (run everywhere)                       = 34
#     …of which 2 are #1256's TZ-invariance falsifier (old needle
#     drifts under UTC / new needle does not, in any timezone)
#     …of which 3 are the DOCUMENTED probes executed (#946 S1):
#     probe 1 (hasattr), probe 3 (version), probe 2's rc
#   + mode-1 silent-zero arm: 3 loud call + 3 idiom              =  6  }
#   + mode-2 arm on the REAL fromisoformat producer              =  5  } only
#   + probe 2's AttributeError assertion (only meaningful <3.7)  =  1  } on <3.7
EXPECTED_ASSERTIONS=35   # +1 in `#1304`: the parse's rc is now asserted separately
[[ "$HAS_FI" == "True" ]] || EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 6 + 5 + 1 ))
TOTAL_ASSERTIONS=$(( PASS + FAIL ))
assert_eq "assertion TOTAL matches the EXPECTED total for this interpreter (fromisoformat=$HAS_FI)" \
          "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
