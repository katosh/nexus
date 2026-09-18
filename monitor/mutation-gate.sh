#!/usr/bin/env bash
# mutation-gate.sh — run ONE mutation experiment against ONE suite, safely.
# (your-org/nexus-code#1032)
#
#   monitor/mutation-gate.sh --suite <path> --list
#   monitor/mutation-gate.sh --suite <path> --line N [--mode delete|duplicate]
#
# ---------------------------------------------------------------------------
# WHY THIS FILE EXISTS AT ALL
# ---------------------------------------------------------------------------
#
# A mutation gate — comment out one assertion, re-run, call the suite "killed"
# if it reddens — is a good instrument and this repo keeps rebuilding it as an
# ad-hoc script in /tmp. One of those (`/tmp/mutgate.sh`, since deleted) chose
# a line ending in a backslash continuation. Commenting line N of a two-line
# assertion does NOT delete the assertion: it promotes line N+1 — the
# assertion's ARGUMENTS — to a standalone command. At
# `test-claude-md-zsh-path-tie.sh:158` the arguments began with a command
# substitution that evaluates to `yes`, so the mutant executed the literal
# command
#
#     yes yes
#
# which wrote ~2 GB/s into the capture file. Two captures reached 223 GB and
# 145 GB; `/tmp` is a 378 GB tmpfs SHARED BY THE ENTIRE SANDBOX and hit 8 KB
# free. A full `/tmp` also fails the tmux socket writes this nexus runs on,
# `bwrap` is PID 1 under `--die-with-parent`, and this sandbox cannot be
# restarted. Seven of twenty-five mutants in that sweep landed on a
# continuation; six merely synthesized `command not found`. WHICH OF THE TWO
# YOU GET IS DECIDED BY TEST DATA, NOT BY THE HARNESS — the rule is "execute
# whatever the first argument expands to".
#
# So this is a SHARED-INFRASTRUCTURE hazard wearing a test bug's clothes, and
# the answer is a tool the next author uses instead of writing their own.
#
# ---------------------------------------------------------------------------
# TWO INDEPENDENT PROPERTIES. NEITHER SUBSTITUTES FOR THE OTHER.
# ---------------------------------------------------------------------------
#
# (1) THE PREDICATE — never mutate a line that is not a complete logical line.
#     Necessary, and NOT sufficient, and the insufficiency is measured rather
#     than supposed. `#1032` proposes rejecting lines that end in `\` and the
#     line after one. That is correct as far as it goes and it does cover a
#     backslash chain of any length (in an N-line chain, lines 1..N-1 all end
#     in `\`, so the successor rule catches line N). But THE CLASS IS NOT
#     BACKSLASHES. Measured on this host, no backslash anywhere:
#
#       printf '%s\n' 'true &&' '  echo PROMOTED' > a.sh
#       sed -i '1s|^|# |' a.sh; bash a.sh      # -> PROMOTED     bash -n rc 0
#
#       printf '%s\n' 'printf "x\n" |' '  tr x Y' > b.sh
#       sed -i '1s|^|# |' b.sh                 # -> `tr` is now standalone and
#                                              #    BLOCKS on stdin  bash -n rc 0
#
#     A trailing `&&`, `||`, `|`, `&`, an open `(`/`{`, an unclosed quote and a
#     heredoc all continue a logical line.
#
#     WHAT THE PREDICATE BELOW ACTUALLY IS, stated correctly because this
#     comment claimed the opposite three times and a skeptic measured the
#     difference: it is a **DENYLIST of enumerated continuation shapes with a
#     permissive default arm** — `ok = 1` is the default and only listed shapes
#     clear it. A construct nobody enumerated is ACCEPTED. That is the shape
#     this repo warns about, and the honest reason it is tolerable here is NOT
#     that the list is complete — it demonstrably was not, see the `<<\TAG`
#     note below — but that property (2) does not consult it at all.
#
#     Writing "allowlist with a default-DENY arm" was aspiration, not
#     description, and aspiration in a coverage claim is how a reader concludes
#     they are covered. If this is ever made a true allowlist, it needs a
#     PARSER: "this line is one complete simple command" cannot be established
#     by matching tokens.
#
#     And syntax checking does not rescue it: `bash -n` returns 0 for the exact
#     `#1032` mutant (measured), because `yes yes` is perfectly valid bash. It
#     is still run below, because it catches a DIFFERENT part of the class (a
#     multi-line `$( )` broke with rc 2), but it is not the guard.
#
# (2) THE STRUCTURAL BOUND — every mutant runs under a wall-clock `timeout`
#     AND a file-size cap AND a free-space check. This is what actually saves
#     you, precisely BECAUSE (1) is a predicate that can be wrong. Measured
#     containment of the real thing:
#
#       timeout 5 bash -c 'ulimit -f 10; exec yes yes' > cap.txt
#       # rc 153 (128+SIGXFSZ), cap.txt = 10240 bytes.  Not 223 GB.
#
#     Four facts about the bound, all measured here, all load-bearing:
#       * `ulimit -f` is an RLIMIT and is INHERITED: a grandchild script that
#         runs `yes yes` is capped too (rc 153, 10240 bytes).
#       * bash's `ulimit -f` unit on this host is 1024 bytes, not the 512 POSIX
#         names — `ulimit -f 1` capped the file at exactly 1024 bytes.
#       * `ulimit -f` DOES NOT BOUND A PIPE. `yes yes | wc -c` under the same
#         cap ran until `timeout` killed it at 3 s (rc 124).
#       * `ulimit -f` IS A PER-FILE LIMIT, NOT A TOTAL BUDGET — and this is the
#         hole that matters most, because it is invisible. Measured: under
#         `ulimit -f 1024` (1 MB per file), a script writing 64 files of 1 MB
#         each completed at rc 0 with EVERY file inside the cap, and `/tmp` lost
#         63 MB. Scale it: nothing about the cap stops a mutant writing
#         hundreds of thousands of compliant files, which is `#1032` again with
#         the cap in place and never firing.
#
#     So NO ONE BOUND IS SUFFICIENT, and they are not redundant — each covers a
#     hole the others do not:
#
#         ulimit -f   per-file SIZE     blind to: many files, pipes
#         timeout     wall CLOCK        blind to: a fast, bounded-time write
#         df drop     TOTAL consumed    the only one that sees the many-files case
#
#     That is why `#1032`'s remedy asks for all three, and why removing the df
#     check because "the cap already covers it" would be wrong.
#
# ---------------------------------------------------------------------------
# (3) A KILL IS NOT EVIDENCE UNLESS IT IS ATTRIBUTABLE
# ---------------------------------------------------------------------------
#
# `#938` says a SURVIVING mutant is not evidence unless the mutation is proven
# to have applied. This is the converse: a KILLED mutant is not evidence unless
# the redness is attributable to the property under test. A mutant that died of
# a syntax error, of the file-size cap, or of the timeout tells you nothing
# about the assertion — and `#1032`'s round-2 duplication mutant produced
# exactly such a false kill, reddening on a mangled call while the suite's
# assertion total stayed at 16 before and 16 after, i.e. the count guard the
# gate existed to exercise was never reached.
#
# So this tool refuses to report a bare "KILLED". It classifies:
#
#   killed-by-assertion   the suite reddened AND its declared assertion total
#                         moved, or a named assertion changed verdict
#   killed-unattributable the suite reddened for a reason the harness caused
#                         (syntax, cap, timeout) — reported, never counted
#   survived              the suite stayed green with the mutation PROVEN applied
#   refused               the line is not safely mutable, the baseline was not
#                         green to begin with, or NEITHER ARM RAN — see below
#
# AND `did-not-run` IS ITS OWN ANSWER, NOT A VERDICT (your-org/nexus-code#1280).
# A suite that SKIPS (rc 77, the automake/POSIX status every `SLOW_TESTS`- and
# `RUN_INTEGRATION`-gated suite in this repo uses) executed no assertion. This
# tool invokes the suite as a bare `bash <suite>` and sets no gating variable,
# so that is the routine case, not an exotic one. Both arms are now checked for
# it, and the general form underneath names no status at all: same exit code on
# both sides AND no declared assertion total on either means every observable
# the verdict could rest on is identical, so there is no verdict. Both refuse
# at rc 3.
#
# EXIT CODES: 0 killed-by-assertion · 4 survived · 5 killed-unattributable /
# inconclusive · 3 REFUSED · 2 usage. Non-zero is not "failure" here; read the
# verdict line.
#
# ---------------------------------------------------------------------------
# (4) WHAT YOU RECORD IS NOT WHAT YOU CHECKED — REPORT THE DIFF, NOT A HASH
# ---------------------------------------------------------------------------
#
# `#1162`. This tool proves application by DIFF (`cmp -s`, then an exact
# changed-line count), which is the right primitive and is already above. The
# residual is in what an author then WRITES DOWN. A `sha256` of the mutated
# file is checkable only against ITSELF: it answers "did this author change the
# file?", never "is the edit I just made the SAME edit?".
#
# Measured, one base tree and one construct, two FAITHFUL mutants of it — a
# `pass`-substitution and an outright deletion. Byte-identical test outcomes,
# DIFFERENT hashes. Neither mutant is wrong. So a second party reproducing the
# work cannot match a recorded hash unless they guess the first author's
# incidental whitespace, and the mismatch then reads as a discrepancy in the
# RESULT when it is a difference in FORMATTING.
#
# That asymmetry is the whole problem: same-author-same-session is where the
# hash always gets exercised, so it LOOKS sufficient, and the one reader who
# most needs the proof — an independent reproducer — is the one guaranteed to
# see a mismatch. A standard whose expected outcome under independent
# reproduction is "mismatch" trains readers to discount mismatches, which is
# the reflex it existed to prevent.
#
# So record the DIFF (or, minimally, the exact replacement text), and pin the
# tree it was applied to. A mutant hash is meaningless without its base:
#
#     git diff --no-index -- <pristine> <mutated>   # WHICH edit — the thing a reproducer needs
#     git rev-parse "<ref>:<path>"                  # the BASE blob, so the tree is pinned
#     sha256sum <mutated>                           # keep, as a SUPPLEMENT: an edit landed
#
# ---------------------------------------------------------------------------
# (5) A COUNT THAT MOVED IS NOT PROOF THE CHANGE APPLIED
# ---------------------------------------------------------------------------
#
# `#1231`, and it is the operational form of (3): it says HOW to attribute.
# A before/after table reported 3 FAILs "with the new skip not firing"; the
# cause was a clone with the fixes STAGED BUT NOT COMMITTED, so the measurement
# ran against a tree that did not contain them. It was caught only because the
# author checked whether the SKIP had FIRED rather than whether the COUNT had
# MOVED — had they checked the count, it would have moved (from the old tree's
# behaviour to the old tree's behaviour under a different invocation) and the
# table would have published.
#
#     A WRONG TREE AND A WORKING FIX BOTH MOVE A NUMBER, so a moved count
#     discriminates NEITHER. Assert the specific NEW BEHAVIOUR the change
#     introduces — a skip that fires, an alarm that names its subject, a
#     branch that is taken — because that is the only observation a wrong
#     tree cannot produce.
#
# This is why `killed-by-assertion` above requires the DECLARED ASSERTION TOTAL
# to move or a NAMED assertion to change verdict, and refuses to count a bare
# redness. Guard, then measure: pin `HEAD` and grep the fixes PRESENT before
# the run, never after. Note where it bites — `#1054`, staged versus
# committed — since a clone, a worktree or a fresh checkout sees the index
# differently from the shell you edited in.
#
# ---------------------------------------------------------------------------
# (6) THE GENERAL FORM, of which every rule above is a special case
# ---------------------------------------------------------------------------
#
# `#938`'s second correspondent, after four instrument failures in two review
# passes — an 11-of-25 population printing `collisions=0`, an inert mutant
# printing `29 passed`, a filter flagging 37 structural artifacts, and a
# one-argument call to a two-argument function printing `*** DOES NOT SEE
# IT ***`. Every one produced a plausible, publishable-looking answer; the last
# was caught ONLY because a positive control failed alongside it.
#
#     A NEGATIVE RESULT WITHOUT A POSITIVE CONTROL IN THE SAME RUN IS NOT A
#     MEASUREMENT.
#
# `grep -c` returning 0, a suite reporting `N passed`, a probe printing `DOES
# NOT SEE IT`, an enumeration returning a count — all fail silently and
# plausibly, and none is distinguishable from a true negative unless something
# in the SAME RUN is known to produce a positive. Proof-of-application works
# precisely because it IS a positive control; it is just the narrowest one.
# Any probe that reports an ABSENCE should carry a control that is expected to
# fire.
#
# ---------------------------------------------------------------------------
# COVERAGE BOUNDARY, one sentence, on the axis the MECHANISM varies on —
# WHICH SHELL CONSTRUCTS CONTINUE A LOGICAL LINE: the predicate recognises
# completeness by scanning tokens against an enumerated list, so a construct
# absent from that list is ACCEPTED, not refused — its failures are therefore
# false ACCEPTANCES as well as false refusals, two were measured (`<<\TAG`
# heredocs, and lines inside a multi-line single-quoted program, which is
# judged per-line), and the bound in (2) is what makes an incomplete predicate
# survivable, because it does not consult the predicate at all.
# ---------------------------------------------------------------------------

set -uo pipefail
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

SUITE=""; LINE=""; MODE=delete; DO_LIST=0; RUN_BOUNDED=""
CAP_KB=262144          # 256 MB. The observed runaway wrote 223 GB.
TIMEOUT_S=300
MIN_FREE_MB=1024
# How much free space the run may consume beyond what the file-size cap can
# account for. Generous ON PURPOSE: `/tmp` here is a tmpfs shared by the whole
# sandbox, so `df` moves under other people's work and a tight threshold would
# halt on somebody else's build. The number that matters is not "did free space
# move" but "did it move by more than this mutant could possibly have written".
MAX_DROP_MB=256
MATCH='^[[:space:]]*(assert_[a-z_]+|ok|bad|no|pass|fail)[[:space:]]'
WORKDIR=""
KEEP_WORKDIR=0

die() { printf 'mutation-gate.sh: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --suite)    SUITE="${2:?--suite needs a path}"; shift 2 ;;
        --line)     LINE="${2:?--line needs an integer}"; shift 2 ;;
        --mode)     MODE="${2:?--mode needs delete|duplicate}"; shift 2 ;;
        --list)     DO_LIST=1; shift ;;
        --cap-kb)   CAP_KB="${2:?}"; shift 2 ;;
        --timeout)  TIMEOUT_S="${2:?}"; shift 2 ;;
        --min-free-mb) MIN_FREE_MB="${2:?}"; shift 2 ;;
        --max-drop-mb) MAX_DROP_MB="${2:?}"; shift 2 ;;
        --match)    MATCH="${2:?}"; shift 2 ;;
        --workdir)  WORKDIR="${2:?}"; shift 2 ;;
        --keep-workdir) KEEP_WORKDIR=1; shift ;;
        --run-bounded) RUN_BOUNDED="${2:?--run-bounded needs a script}"; shift 2 ;;
        # An explicit block, NOT `sed -n '2,10p' "$0"`. A help text addressed by
        # LINE NUMBER silently stops being the help text the moment anyone edits
        # the header above it — a documented form that quietly stops matching
        # what it documents, which is the class this whole tool is about.
        -h|--help)  cat <<'USAGE'; exit 0 ;;
mutation-gate.sh — run ONE mutation experiment against ONE suite, safely.
(your-org/nexus-code#1032)

  mutation-gate.sh --suite <path> --list
  mutation-gate.sh --suite <path> --line N [--mode delete|duplicate]
  mutation-gate.sh --run-bounded <script>        # exercise the BOUND alone

  --list            eligible candidate lines (complete logical lines only)
  --line N          mutate line N
  --mode M          delete (comment out, default) | duplicate
  --match RE        which lines --list offers (default: assertion-shaped)
  --cap-kb N        per-file size cap for the mutant   (default 262144 = 256 MB)
  --timeout S       wall-clock ceiling per run          (default 300)
  --min-free-mb N   halt if the filesystem drops below  (default 1024)
  --max-drop-mb N   allowance for unrelated activity    (default 256)
  --workdir DIR     where captures go (default $TMPDIR/mutgate-$$)
  --keep-workdir    keep the default workdir after exit (a named --workdir is always kept)

EXIT CODES — non-zero is not "failure"; read the VERDICT line.
  0  killed-by-assertion    the suite reddened AND a witness names why
  4  survived               mutation PROVEN applied, suite still green
  5  killed-unattributable  syntax error / cap / timeout / no witness, or a
                            free-space halt. Reported, never counted as evidence.
  3  REFUSED                line not safely mutable, the baseline was not green,
                            EITHER ARM SKIPPED (rc 77 — it did not run), or the two
                            arms are indistinguishable (same rc, no declared
                            assertion total on either side). A refusal is an
                            honest "no answer"; it is never a kill.
  2  usage

THE TWO PROPERTIES, AND WHY BOTH. (1) The predicate refuses any line that is
not a complete logical line — commenting one PROMOTES the next line to a
standalone command; one such mutant ran `yes yes` and filled a shared 378 GB
tmpfs to 8 KB free. (2) The bound (timeout + ulimit -f + a df floor AND drop)
holds when the predicate is wrong, which is the only case in which it matters.
Note `ulimit -f` is PER FILE, not a total budget — 64 files of 1 MB each pass a
1 MB cap and cost 63 MB; the df drop is the only bound that sees that.
USAGE
        *) die "unknown argument: $1" ;;
    esac
done

if [ -z "$RUN_BOUNDED" ]; then
    [ -n "$SUITE" ] || die "--suite is required"
    [ -r "$SUITE" ] || die "suite not readable: $SUITE"
fi
case "$MODE" in delete|duplicate) ;; *) die "--mode must be delete or duplicate" ;; esac
for v in CAP_KB TIMEOUT_S MIN_FREE_MB MAX_DROP_MB; do
    eval "x=\$$v"
    case "$x" in ''|*[!0-9]*) die "--${v,,} must be a non-negative integer (got '$x')" ;; esac
done

if [ -n "$SUITE" ]; then
    SUITE_ABS=$(cd "$(dirname "$SUITE")" && pwd)/$(basename "$SUITE")
    SUITE_DIR=$(dirname "$SUITE_ABS")
fi
# The workdir is OURS unless the caller named one, and ours is removed on
# EXIT. This trap is installed on the line after the allocation, not at the
# apply step 300 lines below where it used to live — that trap removed only
# the mutant COPY ($MUT), so every path out of this script, verdict or `die`,
# left `$TMPDIR/mutgate-$$` behind. Measured 2026-09-03: 4,006 such dirs on a
# tmpfs /tmp, accrued over six days, one per invocation, success paths included
# (96 of a 400-dir sample held a complete baseline+mutant capture set). A
# caller-supplied --workdir is kept — it asked for the captures — and so is
# ours under --keep-workdir, which prints the path so a reader can find it.
WORKDIR_OWNED=0
if [ -z "$WORKDIR" ]; then
    WORKDIR="${TMPDIR:-/tmp}/mutgate-$$"
    WORKDIR_OWNED=1
fi
mkdir -p "$WORKDIR" || die "cannot create workdir: $WORKDIR"
MUT=""
mg_cleanup() {
    [ -n "$MUT" ] && rm -f -- "$MUT"
    if [ "$WORKDIR_OWNED" = 1 ]; then
        if [ "$KEEP_WORKDIR" = 1 ]; then
            printf 'mutation-gate.sh: captures kept at %s\n' "$WORKDIR" >&2
        else
            rm -rf -- "$WORKDIR"
        fi
    fi
}
trap mg_cleanup EXIT

FS_TARGET=$(df -P -- "$WORKDIR" | awk 'NR==2{print $6}')
free_mb() { df -P -m -- "$FS_TARGET" | awk 'NR==2{print $4}'; }

mg_run() {   # <script> <capture-base> -> rc; writes <base>.out/<base>.err
    local script="$1" base="$2" rc
    # `ulimit -f` is in 1024-byte units on this bash (measured), and is an
    # RLIMIT, so it is inherited by every child and grandchild the mutant
    # spawns. `timeout` covers the hole `ulimit -f` cannot: a mutant writing to
    # a PIPE is not bounded by a file-size limit (measured).
    timeout -k 10 "$TIMEOUT_S" \
        bash -c 'ulimit -f "$1" || exit 90; shift; exec bash "$@"' _ "$CAP_KB" "$script" \
        >"$base.out" 2>"$base.err"
    rc=$?
    printf '%s' "$rc"
}

# mg_space_check <free_before_mb> <free_after_mb> -> rc 0 fine, rc 5 HALT
#
# ONE implementation, used by the mutant path AND by `--run-bounded`, so the
# bound that a sweep relies on is the bound the test exercises. A second copy
# here would be a second rule, and a second rule drifts.
mg_space_check() {
    local before="$1" after="$2" drop=$(( $1 - $2 )) cap_mb=$(( CAP_KB / 1024 ))
    printf '  filesystem %s: %s MB free before, %s MB after (drop %s MB)\n' \
           "$FS_TARGET" "$before" "$after" "$drop"
    if [ "$after" -lt "$MIN_FREE_MB" ]; then
        printf 'mutation-gate.sh: HALTING — %s has %s MB free, below the %s MB floor.\n' \
               "$FS_TARGET" "$after" "$MIN_FREE_MB" >&2
        printf '  A shared tmpfs at 8 KB free is how #1032 ended. Refusing to continue a sweep.\n' >&2
        return 5
    fi
    # THE DROP, NOT JUST THE FLOOR. A floor only fires once the damage is nearly
    # done — on a 378 GB tmpfs a mutant can write 300 GB and still leave the
    # floor satisfied. This is the check that notices while there is still room:
    # the cap bounds what the mutant may write TO ITS CAPTURE, so a drop far
    # exceeding the cap means it wrote where the cap does not reach. Both bounds
    # are needed and neither implies the other.
    if [ "$drop" -gt "$(( cap_mb + MAX_DROP_MB ))" ]; then
        printf 'mutation-gate.sh: HALTING — %s lost %s MB during this run.\n' \
               "$FS_TARGET" "$drop" >&2
        printf '  The file-size cap accounts for at most %s MB, and the allowance for\n' "$cap_mb" >&2
        printf '  unrelated activity on this filesystem is %s MB. A drop this large means\n' "$MAX_DROP_MB" >&2
        printf '  something wrote where `ulimit -f` does not reach. Refusing to continue —\n' >&2
        printf '  #1032 filled a SHARED 378 GB tmpfs to 8 KB free, and this host cannot\n' >&2
        printf '  be restarted.\n' >&2
        return 5
    fi
    return 0
}

# mg_is_skip <rc> -> rc 0 when <rc> means "this file DECLINED TO RUN".
#
# A SKIP IS NOT AN OUTCOME (your-org/nexus-code#1280). 77 is the
# automake/POSIX SKIP status and is what every `SLOW_TESTS`/`RUN_INTEGRATION`
# gated suite in this repo exits with when its precondition is absent — and
# this tool invokes the suite as a bare `exec bash "$@"`, setting NEITHER, so
# a self-skip is the ROUTINE case rather than an exotic one.
#
# The list is a variable, not a literal, for the reason `#1280` states: the
# tool must be teachable about the next status the runner learns to emit
# without that becoming a code change at four separate comparison sites.
# 69 (EX_UNAVAILABLE) is the ENVSKIP code (your-org/nexus-code#1283): the suite
# RAN, asserted, and then found the MACHINE unable to supply what it needed.
# Like 77 it means ZERO assertions were evaluated against the mutation, so it
# belongs here for the same reason — but it is NOT the same fact, and the two
# are kept apart in the diagnostics below. Untaught, a 69 fell past this list
# into `killed-unattributable`: a VERDICT rendered on a run that never happened,
# reading as "the mutant WAS caught, just without a named witness", so the line
# gets marked covered. COVERAGE MANUFACTURED FROM AN ABSENCE — `#1280`'s own
# defect ("a mutation that DISABLED the suite is scored as one the suite
# DETECTED — exactly backwards") reproduced for the newer status. The
# status-agnostic arm does not save it: that requires mut_rc == base_rc, and
# 69 != 0.
MG_SKIP_RCS="${MG_SKIP_RCS:-77 69}"
mg_is_skip() {
    case " $MG_SKIP_RCS " in *" $1 "*) return 0 ;; esac
    return 1
}

mg_classify_bound() {   # <rc> -> prints a reason when the BOUND fired, else empty
    case "$1" in
        124|137) printf 'wall-clock timeout at %ss' "$TIMEOUT_S" ;;
        152)     printf 'CPU limit (SIGXCPU)' ;;
        153)     printf 'FILE-SIZE CAP at %s KB (SIGXFSZ) — the mutant was writing without bound' "$CAP_KB" ;;
        *)       printf '' ;;
    esac
}

# Declared assertion total, from the footer both `th_summary_and_exit` and the
# hand-rolled footers print. `?` when the suite speaks a spelling we cannot
# read — NOT `0`, because "no count" and "counted zero" are different claims.
mg_assertions() {
    local f="$1" n
    n=$(sed -n 's/.*=== summary: \([0-9][0-9]*\) passed.*/\1/p' "$f" | tail -1)
    [ -n "$n" ] || n=$(sed -n 's/.*ALL TESTS PASSED (\([0-9][0-9]*\) assertions.*/\1/p' "$f" | tail -1)
    printf '%s' "${n:-?}"
}


# --run-bounded <script>
#
# Run ONE script under exactly the bounds a mutant gets, and print how it ended.
# This exists so the BOUND is testable ON ITS OWN, without a predicate having
# to let something dangerous through first — property (2) must be shown to hold
# when property (1) has already failed, since that is the only case in which it
# matters. `monitor/watcher/test-mutation-gate-bounds.sh` drives it with the
# real `yes yes` the #1032 mutant synthesized.
if [ -n "$RUN_BOUNDED" ]; then
    [ -r "$RUN_BOUNDED" ] || die "not readable: $RUN_BOUNDED"
    rb_free_before=$(free_mb)
    rb_rc=$(mg_run "$RUN_BOUNDED" "$WORKDIR/bounded")
    rb_bound=$(mg_classify_bound "$rb_rc")
    rb_bytes=$(wc -c < "$WORKDIR/bounded.out")
    rb_free_after=$(free_mb)
    printf 'bounded rc=%s bytes=%s cap_kb=%s timeout_s=%s free_before_mb=%s free_after_mb=%s\n' \
           "$rb_rc" "$rb_bytes" "$CAP_KB" "$TIMEOUT_S" "$rb_free_before" "$rb_free_after"
    mg_space_check "$rb_free_before" "$rb_free_after" || exit 5
    if [ -n "$rb_bound" ]; then printf 'CONTAINED: %s\n' "$rb_bound"; exit 5; fi
    printf 'COMPLETED: the script ended on its own (rc %s)\n' "$rb_rc"
    [ "$rb_rc" -eq 0 ] && exit 0 || exit 4
fi

# ---------------------------------------------------------------------------
# THE PREDICATE (1). Allowlist, default-DENY.
# ---------------------------------------------------------------------------
#
# `mg_eligible <file>` prints one row per line of <file>:
#     <lineno><TAB>yes|no<TAB><reason>
# A line is `yes` only when EVERY condition below holds. Anything the scanner
# cannot reason about is `no`, with the reason named — a refusal a human can
# act on beats a silent acceptance nobody can audit.
mg_eligible() {
    awk '
    function ends_with(s, t) { return substr(s, length(s) - length(t) + 1) == t }
    # Count quote characters that are not backslash-escaped. Crude on purpose:
    # it OVER-counts inside single quotes, which produces a REFUSAL, never an
    # acceptance — the safe direction.
    function unescaped(s, ch,   i, n, c, p) {
        n = 0
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1); p = (i > 1) ? substr(s, i-1, 1) : ""
            if (c == ch && p != "\\") n++
        }
        return n
    }
    function strip(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    {
        raw = $0; s = strip($0)
        reason = ""; ok = 1

        # Inside a heredoc: everything is DATA, and commenting data changes the
        # payload rather than the program. Tracked because a `<<EOF` body is
        # full of lines that look exactly like commands.
        if (in_heredoc) {
            if (s == hd_tag) { in_heredoc = 0 }
            ok = 0; reason = "inside a heredoc body"
            print NR "\t" "no" "\t" reason
            prev = s; next
        }
        # Blank/comment FIRST. A `<<TAG` inside a comment is not a heredoc, and
        # mistaking one for a heredoc start would mark every following line
        # ineligible — a refusal cascade that reads exactly like "this suite has
        # no candidates". Ordering is the whole fix.
        if (s == "")                      { print NR "\tno\tblank";            prev = s; next }
        if (substr(s, 1, 1) == "#")       { print NR "\tno\talready a comment"; prev = s; next }

        # `\\?` IS LOAD-BEARING. `cat <<\TAG` is a real, POSIX heredoc form —
        # the backslash quotes the delimiter exactly as `<<'"'"'TAG'"'"'` does — and the
        # regex here recognised only quote and bare forms, so it ACCEPTED the
        # opener. Commenting it then promoted the heredoc BODY, and a skeptic
        # drove that end to end: the body was `yes yes`, i.e. the #1032 payload
        # itself, reached through the very predicate written to prevent it. (The
        # structural bound caught it — rc 153, exactly 8192 B — which is the
        # layered design working as its header promises, not a reason to leave
        # the hole.) Zero in-tree instances at the time of writing, positive
        # control fired, so it was latent rather than live.
        if (match(raw, /<<-?[ \t]*[\"\x27\\]?[A-Za-z_][A-Za-z0-9_]*/)) {
            hd = substr(raw, RSTART, RLENGTH)
            sub(/^<<-?[ \t]*/, "", hd); gsub(/[\"\x27\\]/, "", hd)
            in_heredoc = 1; hd_tag = hd
            ok = 0; reason = "opens a heredoc"
        }

        # The line itself must END a logical line.
        if (ok) {
            # BREAK on the first match, and the list is ordered LONGEST FIRST.
            # Without the break the LAST match won, so `&&` was reported as
            # `continuation token: &` — a correct refusal naming the wrong token,
            # which sends the reader looking for a construct that is not there.
            for (i = 1; i <= n_cont; i++)
                if (ends_with(s, cont[i])) { ok = 0; reason = "ends with a continuation token: " cont[i]; break }
        }
        # …and it must BEGIN one: the previous meaningful line must not have
        # continued into it. This is the rule that would have stopped #1032.
        if (ok && prev != "") {
            for (i = 1; i <= n_cont; i++)
                if (ends_with(prev, cont[i])) { ok = 0; reason = "continues the previous line (which ends with " cont[i] ")"; break }
        }
        # Unbalanced quoting means the logical line spans further than this one.
        if (ok && unescaped(s, "\"") % 2 == 1)   { ok = 0; reason = "odd number of unescaped double quotes" }
        if (ok && unescaped(s, "\x27") % 2 == 1) { ok = 0; reason = "odd number of unescaped single quotes" }
        # Unbalanced grouping, same argument.
        if (ok && (gsub(/\(/, "(", s) != gsub(/\)/, ")", s))) { ok = 0; reason = "unbalanced parentheses" }
        s = strip($0)
        if (ok && (gsub(/\{/, "{", s) != gsub(/\}/, "}", s))) { ok = 0; reason = "unbalanced braces" }
        s = strip($0)

        print NR "\t" (ok ? "yes" : "no") "\t" reason
        prev = s
    }
    BEGIN {
        # The tokens that continue a logical line in bash. ENUMERATED, and the
        # default arm is DENY, so a construct missing from this list costs a
        # refusal rather than a runaway.
        # The return value of split() IS the count. Writing the count by hand is
        # how the last element silently stops being checked, which is the same
        # off-by-one family this repo keeps paying for.
        n_cont = split("\\ && || | & ; , ( { [ then do else elif in", cont, " ")
    }' "$1"
}

if [ "$DO_LIST" -eq 1 ]; then
    printf '# eligible mutation candidates in %s\n' "$SUITE_ABS"
    printf '# (a line is listed only if it matches --match AND is a complete logical line)\n'
    n=0
    while IFS=$'\t' read -r ln verdict reason; do
        [ "$verdict" = yes ] || continue
        text=$(sed -n "${ln}p" "$SUITE_ABS")
        grep -qE "$MATCH" <<<"$text" || continue
        printf '%s\t%s\n' "$ln" "$text"; n=$((n+1))
    done < <(mg_eligible "$SUITE_ABS")
    printf '# %d eligible line(s)\n' "$n"
    [ "$n" -gt 0 ] || { printf 'mutation-gate.sh: REFUSED — no eligible line (a zero here is a MEASURED answer, not a green light).\n' >&2; exit 3; }
    exit 0
fi

[ -n "$LINE" ] || die "--line is required (or --list)"
case "$LINE" in ''|*[!0-9]*) die "--line must be an integer" ;; esac

TOTAL=$(wc -l < "$SUITE_ABS")
[ "$LINE" -ge 1 ] && [ "$LINE" -le "$TOTAL" ] || die "--line $LINE is outside 1..$TOTAL"

# ---------------------------------------------------------------------------
# ELIGIBILITY — refuse before anything is written.
# ---------------------------------------------------------------------------
elig=$(mg_eligible "$SUITE_ABS" | awk -F'\t' -v L="$LINE" '$1==L{print $2 "\t" $3}')
if [ "${elig%%$'\t'*}" != yes ]; then
    printf 'mutation-gate.sh: REFUSED — line %s of %s is not safely mutable.\n' "$LINE" "$SUITE_ABS" >&2
    printf '  reason : %s\n' "${elig#*$'\t'}" >&2
    printf '  line   : %s\n' "$(sed -n "${LINE}p" "$SUITE_ABS")" >&2
    printf '  why    : commenting a line that does not END a logical line promotes the NEXT\n' >&2
    printf '           line to a standalone command. One such mutant synthesized `yes yes`\n' >&2
    printf '           and filled a shared 378 GB tmpfs (your-org/nexus-code#1032).\n' >&2
    printf '  next   : %s --suite %q --list\n' "$0" "$SUITE_ABS" >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# THE BOUND (2) — one runner, used for the baseline AND the mutant, so the two
# are comparable and the baseline proves the bound does not itself redden a
# healthy suite.
# ---------------------------------------------------------------------------
free_before=$(free_mb)

echo "=== baseline: $SUITE_ABS (unmutated) ==="
base_rc=$(mg_run "$SUITE_ABS" "$WORKDIR/baseline")
base_bound=$(mg_classify_bound "$base_rc")
if [ -n "$base_bound" ]; then
    printf 'mutation-gate.sh: REFUSED — the UNMUTATED suite hit a bound (%s).\n' "$base_bound" >&2
    printf '  Raise --timeout/--cap-kb, or fix the suite. A kill measured against a\n' >&2
    printf '  baseline that the harness itself reddens is not evidence.\n' >&2
    exit 3
fi
# A SKIPPED BASELINE IS NOT A GREEN BASELINE — and this arm used to say it was
# (your-org/nexus-code#1280). The condition read `-ne 0 && -ne 77`, i.e. 77 was
# admitted as green, so a `SLOW_TESTS`-gated suite proceeded to a mutation
# experiment in which ZERO assertions ran in EITHER arm. Because the mutant arm
# grants `survived` only on rc 0, the identical 77 then fell all the way through
# to `killed-unattributable` — the tool reporting a KILL for a suite that never
# executed a line. `did-not-run` rendered as a verdict, in the one tool the
# worker floor tells agents to trust INSTEAD of their own hand-rolled mutant.
#
# Refusing here rather than at the mutant is deliberate: it is the EARLIEST
# point at which the truth is known, it costs the caller nothing (the mutant
# could not have run either), and the diagnostic can name the remedy while the
# reader still has the suite in mind. Fail CLOSED — rc 3, as every other
# unanswerable question in this file does.
if mg_is_skip "$base_rc"; then
    printf 'mutation-gate.sh: REFUSED — the UNMUTATED suite SKIPPED (rc %s). It did not run.\n' "$base_rc" >&2
    printf '  Zero assertions executed, so there is nothing for a mutation to be measured\n' >&2
    printf '  against. This is NOT a green baseline and NOT a kill; it is an absence.\n' >&2
    if [ "$base_rc" = "69" ]; then
        # BOTH arms need the distinction, not just the mutant one
        # (your-org/nexus-code#1283). Before 69 was taught to MG_SKIP_RCS this
        # baseline fell to the `-ne 0` arm below and was reported as "the
        # UNMUTATED suite is not green … already red" — loud, but MISDIAGNOSED:
        # it was not red, it DECLINED. Naming it correctly is the difference
        # between "fix your suite" and "run this somewhere else".
        printf '  rc 69 is ENVSKIP: the suite RAN and then declined on MEASURED ENVIRONMENT\n' >&2
        printf '  grounds — NOT the gate, and NOT a red baseline. No gating variable will\n' >&2
        printf '  change it.\n' >&2
        printf '  next   : re-run on a machine that can build the fixture, or read the ENV\n' >&2
        printf '           line below and satisfy what it names.\n' >&2
    else
        printf '  This tool runs the suite as a bare `bash <suite>` and sets no gating variable,\n' >&2
        printf '  so a gated suite self-skips here even when it passes under the runner.\n' >&2
        printf '  next   : re-run with the gate the suite asks for in its skip line, e.g.\n' >&2
        printf '           SLOW_TESTS=1 %s --suite %q --line %s\n' "$0" "$SUITE_ABS" "$LINE" >&2
    fi
    printf '  Skip line: %s\n' "$(tail -3 "$WORKDIR/baseline.out" | tr '\n' ' ')" >&2
    exit 3
fi
if [ "$base_rc" -ne 0 ]; then
    printf 'mutation-gate.sh: REFUSED — the UNMUTATED suite is not green (rc %s).\n' "$base_rc" >&2
    printf '  A mutant cannot be shown to have killed a suite that was already red.\n' >&2
    # `tail -n 5`, NOT `tail -5`. The obsolete `-N` form is REJECTED when more
    # than one file is named — measured on this host, GNU coreutils:
    # `tail -5 a b` -> `tail: option used in invalid context -- 5`, rc 1, and
    # NOTHING printed. So this refusal promised "Last lines:" and then showed
    # none, every time it fired. Found by driving this arm from
    # test-mutation-gate-did-not-run.sh MUTANT 4; a diagnostic nobody reads
    # until something is already wrong is exactly where a silent empty stays
    # silent.
    printf '  Last lines:\n' >&2; tail -n 5 "$WORKDIR/baseline.err" "$WORKDIR/baseline.out" >&2
    exit 3
fi
base_assert=$(mg_assertions "$WORKDIR/baseline.out")
printf '  baseline rc=%s  declared assertions=%s\n' "$base_rc" "$base_assert"

# ---------------------------------------------------------------------------
# APPLY — to a COPY beside the original, so the tracked file is never edited.
# Beside it, not in $TMPDIR: a suite resolves its fixtures from
# `dirname "${BASH_SOURCE[0]}"`, and moving it would change what is under test.
# The name begins with a dot so no `test-*.sh` glob can pick it up.
# ---------------------------------------------------------------------------
MUT="$SUITE_DIR/.mutgate-$$-$(basename "$SUITE_ABS")"
# Removed by mg_cleanup (installed beside the workdir allocation above).

case "$MODE" in
  delete)    awk -v L="$LINE" 'NR==L{ printf "# %s\n", $0; next } { print }' "$SUITE_ABS" > "$MUT" ;;
  duplicate) awk -v L="$LINE" 'NR==L{ print; print; next } { print }'        "$SUITE_ABS" > "$MUT" ;;
esac
chmod --reference="$SUITE_ABS" "$MUT" 2>/dev/null || chmod +x "$MUT"

# PROVE THE MUTATION APPLIED (#938). An INERT mutant and a genuinely surviving
# one produce byte-identical output — green suite, "SURVIVED" — so a sweep that
# does not check this can report a coverage hole that does not exist, or miss
# one that does.
if cmp -s "$SUITE_ABS" "$MUT"; then
    printf 'mutation-gate.sh: REFUSED — the mutation did not change the file. Nothing was tested.\n' >&2
    exit 3
fi
changed=$(diff <(cat "$SUITE_ABS") <(cat "$MUT") | grep -c '^[<>]')
mut_line=$(sed -n "${LINE}p" "$MUT")
case "$MODE" in
  delete)
    case "$mut_line" in
      '#'*) : ;;
      *) printf 'mutation-gate.sh: REFUSED — line %s of the mutant is not a comment: %s\n' "$LINE" "$mut_line" >&2; exit 3 ;;
    esac
    [ "$changed" -eq 2 ] || { printf 'mutation-gate.sh: REFUSED — expected exactly one changed line, diff shows %s\n' "$changed" >&2; exit 3; } ;;
  duplicate)
    [ "$changed" -eq 1 ] || { printf 'mutation-gate.sh: REFUSED — expected exactly one added line, diff shows %s\n' "$changed" >&2; exit 3; } ;;
esac
printf '  mutation applied and verified at line %s (mode=%s)\n' "$LINE" "$MODE"

# A mutant that does not PARSE is a kill for a reason having nothing to do with
# the assertion. Caught here so it is reported as such rather than counted.
if ! bash -n "$MUT" 2>"$WORKDIR/parse.err"; then
    printf 'VERDICT: killed-unattributable (the mutant does not parse)\n'
    printf '  %s\n' "$(head -2 "$WORKDIR/parse.err" | tr '\n' ' ')"
    printf '  A syntax kill says nothing about the assertion. Not evidence.\n'
    exit 5
fi

echo "=== mutant ==="
mut_rc=$(mg_run "$MUT" "$WORKDIR/mutant")
mut_bound=$(mg_classify_bound "$mut_rc")
free_after=$(free_mb)

# THE FREE-SPACE BACKSTOP. `ulimit -f` bounds regular-file writes and `timeout`
# bounds wall clock; neither bounds a mutant that fills a filesystem through a
# path the harness does not own. This is the check that notices anyway.
mg_space_check "$free_before" "$free_after" || exit 5

if [ -n "$mut_bound" ]; then
    printf 'VERDICT: killed-unattributable (%s)\n' "$mut_bound"
    printf '  The HARNESS stopped this mutant; the suite never rendered a verdict on it.\n'
    printf '  Contained: capture is %s bytes (cap %s KB).\n' "$(wc -c < "$WORKDIR/mutant.out")" "$CAP_KB"
    printf '  This is the #1032 shape. Inspect line %s before re-running anything.\n' "$LINE"
    exit 5
fi

mut_assert=$(mg_assertions "$WORKDIR/mutant.out")
printf '  mutant rc=%s  declared assertions=%s (baseline %s)\n' "$mut_rc" "$mut_assert" "$base_assert"

# ---------------------------------------------------------------------------
# THE ARMS MUST BE DISTINGUISHABLE (your-org/nexus-code#1280).
#
# TWO INDEPENDENT CONDITIONS. Neither subsumes the other, and both sit ABOVE
# both verdicts on purpose — the defect class is "did-not-run rendered as a
# verdict", and it has TWO directions. `killed-unattributable` is the one that
# was reported; `survived` is the same error wearing the opposite sign, and it
# is the WORSE of the two, because `survived` is read as "nothing asserts this
# line" and sends a worker to write coverage that already exists.
#
# (1) A SKIP IS NOT A KILL. The baseline arm now refuses a skipped baseline,
#     so `base_rc` is 0 by the time control reaches here. That does NOT make
#     this arm dead: the mutation can itself steer the suite onto a skip path
#     it did not take unmutated — comment out the line that sets the variable
#     a `[ -n "$X" ] || exit 77` guard reads, and a suite that ran cleanly at
#     baseline declines to run as a mutant. Direction matters: today that
#     lands on `killed-unattributable`, i.e. a mutation that DISABLED the
#     suite is scored as a mutation the suite DETECTED. Exactly backwards.
if mg_is_skip "$mut_rc"; then
    printf 'mutation-gate.sh: REFUSED — the MUTANT SKIPPED (rc %s). It did not run.\n' "$mut_rc" >&2
    printf '  The baseline ran (rc %s, %s assertions) and the mutant declined to. Zero\n' "$base_rc" "$base_assert" >&2
    printf '  assertions were evaluated against the mutation, so this is neither a kill\n' >&2
    printf '  nor a survival — the experiment did not happen.\n' >&2
    if [ "$mut_rc" = "69" ]; then
        # ENVSKIP, not a gate-skip. Collapsing the two re-creates the exact
        # collision `#1283` exists to separate, and the gate advice below would
        # be actively wrong here: no gate variable will fix a machine that
        # could not supply the fixture.
        printf '  rc 69 is ENVSKIP: the suite RAN and then declined on MEASURED ENVIRONMENT\n' >&2
        printf '  grounds — NOT the gate. Re-running with a gate set will not change it;\n' >&2
        printf '  re-run on a machine that can build the fixture, or read the ENV line below.\n' >&2
    else
        printf '  Line %s most likely feeds a precondition the suite gates itself on. Read it\n' "$LINE" >&2
        printf '  before treating this line as covered or uncovered.\n' >&2
    fi
    printf '  Mutant skip line: %s\n' "$(tail -3 "$WORKDIR/mutant.out" | tr '\n' ' ')" >&2
    exit 3
fi
# (2) THE GENERAL FORM, WHICH NAMES NO STATUS AT ALL. Condition (1) is a list
#     of statuses and is therefore incomplete by construction — the next thing
#     the runner learns to emit is not on it. This one asks the question the
#     status list is a proxy for: DID THE TWO ARMS DIFFER IN ANY WAY THIS TOOL
#     CAN SEE? Same exit status, and no declared assertion total on either
#     side, means every observable the verdict could rest on is identical
#     between a run with the mutation and a run without it. There is no
#     verdict in that; there is only an absence.
#
#     `?` is not `0`: `mg_assertions` returns it when the suite speaks a
#     spelling this tool cannot read, which is precisely the case in which a
#     green mutant cannot be told from a mutant that never asserted anything.
#     A suite that DOES declare its total is unaffected — the legitimate
#     `survived` of an assertion line moves the count, and the legitimate
#     `survived` of a non-assertion line leaves a count that is KNOWN, so
#     neither trips this. Verified against `test-mutation-gate-bounds.sh` §3b,
#     which is exactly that second shape and must keep exiting 4.
if [ "$mut_rc" -eq "$base_rc" ] && [ "$base_assert" = '?' ] && [ "$mut_assert" = '?' ]; then
    printf 'mutation-gate.sh: REFUSED — the two arms are INDISTINGUISHABLE (both rc %s, neither declares an assertion total).\n' "$mut_rc" >&2
    printf '  Every observable this tool can read is identical with and without the\n' >&2
    printf '  mutation, so no verdict is supportable in either direction. Reporting\n' >&2
    printf '  `survived` here would claim nothing asserts line %s; reporting a kill would\n' "$LINE" >&2
    printf '  claim something did. Both would be manufactured from an absence.\n' >&2
    printf '  next   : make the suite declare its total — `th_summary_and_exit` prints\n' >&2
    printf '           `=== summary: N passed, M failed ===`, which is what this tool reads.\n' >&2
    exit 3
fi

if [ "$mut_rc" -eq 0 ]; then
    printf 'VERDICT: survived\n'
    printf '  The mutation was PROVEN applied (diff checked above) and the suite still\n'
    printf '  passed — so nothing in it asserts what line %s asserts.\n' "$LINE"
    exit 4
fi

# KILLED. Now say WHY, which is the whole of (3).
#
# THE ORDER OF THESE TWO WITNESSES IS LOAD-BEARING, and the first draft had it
# backwards. A suite with an EXACT COUNT GUARD reddens on EVERY deletion mutant
# — the guard notices one fewer assertion ran — so "the declared total moved" is
# always available and always true there. Reported first, it would dress up the
# count guard as evidence that line N's assertion is load-bearing, which it is
# not: the same witness appears for a line nothing else depends on. Found by
# running this tool against a count-guarded suite written in the same change,
# where every mutant came back with the identical witness.
#
# So a NAMED assertion that changed verdict is preferred, and the count-guard
# case is labelled as the weaker thing it is. `grep -m1` already stops at the
# first match, so no `| head -1` (that would be an early-exit reader whose
# pipeline status nothing consumes — a construct this repo lints for).
witness=""
named=$(grep -m1 -h -E '^[[:space:]]*FAIL: ' "$WORKDIR/mutant.out" "$WORKDIR/mutant.err" 2>/dev/null)
# Discard the count guard when it wears the canonical spelling. This is a
# predicate keyed on a STRING, so it is INCOMPLETE by construction: a suite is
# free to spell its count guard as an ordinary `assert_eq "assertion TOTAL
# matches …"`, and one in this repo does. Both known spellings are matched, the
# match is case-insensitive, and the residue is handled by PRINTING the witness
# so a reader can see what it actually says — a label the tool cannot verify is
# better shown than asserted.
if grep -qiE 'ASSERTION COUNT MISMATCH|assertion (count|total)' <<<"$named"; then
    named=""
fi
if [ -n "$named" ]; then
    witness="a named assertion changed verdict: ${named#*FAIL: }"
elif [ "$base_assert" != '?' ] && [ "$mut_assert" != '?' ] && [ "$base_assert" != "$mut_assert" ]; then
    witness="COUNT GUARD ONLY — the declared total moved ($base_assert -> $mut_assert), and no"
    witness="$witness
           named assertion changed verdict. In a count-guarded suite EVERY deletion
           mutant is killed this way, so this shows the guard works; it does NOT
           show that line $LINE's assertion is load-bearing."
fi
if [ -n "$witness" ]; then
    printf 'VERDICT: killed-by-assertion\n'
    printf '  witness: %s\n' "$witness"
    # Only on the STRONG arm: the weak arm already says what it is, and a caveat
    # repeated under a message that already carries it trains the reader to skip
    # both.
    if [ -n "$named" ]; then
        printf '  READ THE WITNESS. If it names a COUNT rather than a BEHAVIOUR, it is the\n'
        printf '  count guard of the suite under a spelling this tool did not recognise —\n'
        printf '  the discrimination is by STRING and is therefore incomplete.\n'
    fi
    exit 0
fi
printf 'VERDICT: killed-unattributable (rc %s, no witness)\n' "$mut_rc"
printf '  The suite reddened and the harness cannot name WHICH assertion did it.\n'
printf '  #1032 round 2 produced exactly this: a red whose assertion total was\n'
printf '  16 before and 16 after, i.e. the count guard was never reached.\n'
exit 5
