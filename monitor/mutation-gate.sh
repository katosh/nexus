#!/usr/bin/env bash
# mutation-gate.sh — run ONE mutation experiment against ONE suite, safely.
# (your-org/nexus-code#1032)
#
#   monitor/mutation-gate.sh --suite <path> --list
#   monitor/mutation-gate.sh --suite <path> --line N [--mode delete|duplicate]
#   monitor/mutation-gate.sh --suite <path> --subject <path> --list
#   monitor/mutation-gate.sh --suite <path> --subject <path> --line N \
#           [--mode delete|duplicate|if-true|if-false|subst --from S --to R] \
#           [--predict F] [--record TSV]
#   monitor/mutation-gate.sh --provenance TSV --suite <path> [--labels-from F]
#
# TWO DIFFERENT QUESTIONS, AND UNTIL `#1519` THIS TOOL COULD ASK ONLY THE FIRST.
# Read section (7) below before you cite a mutation round in a report.
#
#   --suite alone        mutates THE SUITE. Answers: "is this assertion REACHED —
#                        does removing it change the verdict?"
#   --suite + --subject  mutates THE CODE UNDER TEST and runs the suite against
#                        it. Answers: "would this suite CATCH A DEFECT here?"
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
# inconclusive · 3 REFUSED · 2 usage · 6 a verdict WAS rendered and the
# registered `--predict` was REFUTED (section 8). Non-zero is not "failure"
# here; read the verdict line.
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
# (7) MUTATING THE SUITE IS NOT MUTATING THE SUBJECT (your-org/nexus-code#1519)
# ---------------------------------------------------------------------------
#
# For its first life this tool took `--suite` only and mutated AND ran the same
# file. That answers "is this assertion REACHED". It cannot answer "would this
# suite catch a defect in the code under test" — and that second question is
# what "I mutation-tested my suite" is read to mean in a report.
#
# WHAT EVERY SUITE-MUTATION RESULT ESTABLISHES, AND WHAT IT DOES NOT. A
# `killed-by-assertion` from a `--suite`-only round shows that the assertion
# executes and that the suite's verdict depends on it. It does NOT show that
# the assertion would FAIL if the code were wrong, because the code was never
# changed. The measured gap (`#1518`, a hand-rolled subject sweep over
# `_auth_hold.sh`): three assertions were green FOR THE WRONG REASON — each
# NAMED one guard and was in fact DEFENDED BY A DIFFERENT ONE. A fresh-hold
# assertion used an age the grace guard already refused, so deleting the escape
# threshold left it green. Every one of those assertions was reached, so a
# suite-mutation round reports every one of them load-bearing. Any report that
# cites a `--suite`-only round as evidence that a suite "catches defects"
# inherited a claim the instrument could not support; the honest reading is
# "the assertions are reached".
#
# SUBJECT MODE, AND THE THREE WAYS IT WOULD OTHERWISE LIE:
#
#   (a) THE TRACKED FILE IS NEVER EDITED. A subject is production code; the
#       watcher may be sourcing it. Both arms run in THROWAWAY COPIES of the
#       working tree (`git ls-files -co --exclude-standard`: tracked plus
#       untracked-unignored, WORKING-TREE content, so an uncommitted suite is
#       included), each made its own git repository so a population guard's
#       `git ls-files` answers about the COPY. The baseline arm is the positive
#       control for the copy: a suite that cannot go green there is REFUSED.
#       BOUNDARY: GITIGNORED files are NOT copied (the WORKTREE-BLIND-SPOT,
#       `#1150`). A fixture-gated sub-check that skips in BOTH arms cannot
#       flip, so the error direction is FALSE SURVIVORS — this under-claims
#       coverage, never over-claims it. The count of uncopied ignored paths is
#       printed on every run.
#
#   (b) AN INERT MUTANT READS AS `survived`. A suite that resolves its subject
#       through `$NEXUS_ROOT`, an absolute path or an installed copy never
#       reads the mutated file; the suite stays green and the tool would report
#       "nothing asserts this line" about a line the suite never saw. So a
#       LOAD WITNESS — one `echo x >> <file>` line — is planted at the top of the
#       subject copy in BOTH arms (identical, so the arms still differ only by
#       the mutation). An empty baseline witness is a REFUSAL (rc 3) before the
#       mutant is even built: the suite does not execute this copy of the
#       subject. It proves the FILE was executed, not that LINE N was reached —
#       deliberately: a suite that never reaches line N would not catch a
#       defect there, so `survived` is the correct verdict for it.
#       `--no-load-witness` exists for a subject whose CONTENT a suite pins
#       (a hash, a header lint); a survivor is then `survived-unwitnessed`,
#       rc 5, never evidence.
#
#   (c) DELETING AN `if` IS A SYNTAX KILL, which says nothing. The realistic
#       mutant for a guard is to WEAKEN it: `--mode if-true` / `--mode if-false`
#       rewrite the condition of a single-line `if …; then` / `elif …; then`
#       and leave the line's structure alone, so nothing is promoted (the
#       `#1032` hazard needs a line to DISAPPEAR). `if-true` is the EAGER
#       direction, `if-false` the lazy one; a guard wants both.
#       A COMPOUND condition spans lines, and the if-* modes refuse it. For
#       that, `--mode subst --from S --to R` rewrites text INSIDE one line
#       (`streak >= CAP` -> `streak >= 1`) and is accepted only when the new
#       line provably has the old line's structure: same first and last word,
#       and the same count of every character that quotes, groups, joins or
#       continues. Strict on purpose — `&&` -> `||` is refused.
#
# A MUTANT THAT LANDS ON A COMMENT is refused by the same predicate as in suite
# mode ("already a comment"): a pattern that matched a comment MENTIONING a call
# rather than the call is a mutant that changes nothing and a green that means
# nothing — a predicate keyed on a STRING meeting the description of the thing.
#
# ---------------------------------------------------------------------------
# (8) THE FLIP SET, THE PREDICTION, AND PROVENANCE (your-org/nexus-code#1510)
# ---------------------------------------------------------------------------
#
# A verdict line says THAT a suite reddened; the FLIP SET says WHICH cases did
# — every label that printed `PASS:` at baseline and `FAIL:` in the mutant.
# Printed on every kill, with the cases that VANISHED (ran at baseline, never
# ran in the mutant) beside it, because a case that did not run is not a case
# that passed.
#
# `--predict F` registers a prediction BEFORE the run: `+text` names a case
# that must flip, `-text` one that must NOT. It is a prediction of a SET, so it
# is EXHAUSTIVE: a case that flipped and that no `+` line names is UNPREDICTED,
# and refutes the prediction exactly as a `+` that did not flip does. Without it a survivor is trivially
# rationalised after the fact, and a round that kills everything is as
# uninformative as one that kills nothing — so a prediction with no `-` line is
# called out. Every line must match a baseline case (a typo'd prediction is a
# vacuous one: REFUSED). A refuted prediction exits 6: the verdict stands, and
# the author's model of their own suite was wrong, which is the finding.
#
# `--record TSV` appends one row per flipped case (and one for a survivor),
# with the prediction snapshot's blob hash, so "written before the run" is a
# checkable column rather than a sentence.
# `--provenance TSV --suite S` then reads it back against the suite's CURRENT
# cases: `GUARDED` (a recorded kill at the current suite and subject blobs),
# `GUARDED-STALE` (killed once, but the suite or subject has changed since),
# `NEVER-KILLED`. That is the distinction `#1510` found missing: a case that
# survived ten mutants and a case added yesterday both print `PASS`, and cases
# added AFTER a round inherit its green without earning it. Exit 0 only when
# every case is GUARDED; 4 otherwise.
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
MATCH_SET=0
WORKDIR=""
KEEP_WORKDIR=0
# Subject mode, prediction and provenance (sections 7 and 8 of the header).
SUBJECT=""; PREDICT=""; RECORD=""; PROVENANCE=""; LABELS_FROM=""; LOAD_WITNESS=1
SUBST_FROM=""; SUBST_TO=""; SUBST_TO_SET=0

die() { printf 'mutation-gate.sh: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --suite)    SUITE="${2:?--suite needs a path}"; shift 2 ;;
        --subject)  SUBJECT="${2:?--subject needs a path}"; shift 2 ;;
        --predict)  PREDICT="${2:?--predict needs a file}"; shift 2 ;;
        --record)   RECORD="${2:?--record needs a tsv path}"; shift 2 ;;
        --provenance) PROVENANCE="${2:?--provenance needs a tsv path}"; shift 2 ;;
        --labels-from) LABELS_FROM="${2:?--labels-from needs a captured suite stdout}"; shift 2 ;;
        --no-load-witness) LOAD_WITNESS=0; shift ;;
        --line)     LINE="${2:?--line needs an integer}"; shift 2 ;;
        --mode)     MODE="${2:?--mode needs delete|duplicate|if-true|if-false|subst}"; shift 2 ;;
        --from)     SUBST_FROM="${2:?--from needs the text to replace}"; shift 2 ;;
        --to)       [ $# -ge 2 ] || die "--to needs the replacement text"; SUBST_TO="$2"; SUBST_TO_SET=1; shift 2 ;;
        --list)     DO_LIST=1; shift ;;
        --cap-kb)   CAP_KB="${2:?}"; shift 2 ;;
        --timeout)  TIMEOUT_S="${2:?}"; shift 2 ;;
        --min-free-mb) MIN_FREE_MB="${2:?}"; shift 2 ;;
        --max-drop-mb) MAX_DROP_MB="${2:?}"; shift 2 ;;
        --match)    MATCH="${2:?}"; MATCH_SET=1; shift 2 ;;
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
  mutation-gate.sh --suite <path> --subject <path> --list
  mutation-gate.sh --suite <path> --subject <path> --line N [--mode M] [--predict F] [--record TSV]
  mutation-gate.sh --provenance TSV --suite <path> [--labels-from F]
  mutation-gate.sh --run-bounded <script>        # exercise the BOUND alone

TWO QUESTIONS. `--suite` alone mutates the SUITE: "is this assertion REACHED?"
`--suite` + `--subject` mutates the CODE UNDER TEST and runs the suite against
it: "would this suite CATCH A DEFECT here?" Only the second supports the claim
"my suite is load-bearing" (your-org/nexus-code#1519). The tracked subject is
never edited: both arms run in throwaway copies of the working tree.

  --list            eligible candidate lines (complete logical lines only), and
                    the single-line `if`/`elif` lines the if-* modes accept
  --line N          mutate line N (of the subject when --subject is given)
  --mode M          delete (comment out, default) | duplicate
                    | if-true | if-false   force a single-line `if …; then`
                    condition (eager / lazy). Deleting an `if` is a syntax
                    kill; weakening it is the realistic mutant.
                    | subst --from S --to R   rewrite text INSIDE the line —
                    for a compound condition spanning lines. Refused unless
                    the line keeps its first/last word and the count of every
                    quoting, grouping, joining and continuation character.
  --subject P       the code under test. Must be a SHELL file in the same
                    repository as the suite.
  --no-load-witness do not plant the load witness in the subject copy. A
                    survivor is then `survived-unwitnessed` (rc 5): it cannot
                    be told from a mutant the suite never read.
  --predict F       a prediction written BEFORE the run. One per line:
                    `+text` a case (label substring) that must flip,
                    `-text` a case that must NOT. EXHAUSTIVE: a flipped case
                    no `+` line names is UNPREDICTED. Refuted -> exit 6.
  --record TSV      append provenance rows (one per flipped case)
  --provenance TSV  report which of the suite's CURRENT cases a recorded round
                    has ever killed: GUARDED | GUARDED-STALE | NEVER-KILLED
  --labels-from F   with --provenance: read the cases from a captured suite
                    stdout instead of running the suite
  --match RE        which lines --list offers (default: assertion-shaped for a
                    suite, every eligible line for a subject)
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
                            assertion total on either side). In subject mode also:
                            the suite never EXECUTED the copy of the subject (an
                            inert mutant), the subject is not a shell file, or a
                            --predict line names no baseline case. A refusal is an
                            honest "no answer"; it is never a kill.
  6  PREDICTION REFUTED     a verdict was rendered (printed above) and the
                            registered --predict did not hold. The finding is
                            about the AUTHOR'S MODEL of the suite.
  2  usage
  --provenance: 0 every current case GUARDED · 4 some NEVER-KILLED or STALE · 3 REFUSED

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
case "$MODE" in delete|duplicate|if-true|if-false|subst) ;; *) die "--mode must be delete, duplicate, if-true, if-false or subst" ;; esac
if [ "$MODE" = subst ]; then
    [ -n "$SUBST_FROM" ] && [ "$SUBST_TO_SET" = 1 ] || die "--mode subst needs --from TEXT and --to TEXT"
    case "$SUBST_FROM$SUBST_TO" in *$'\n'*) die "--from/--to must each be a single line" ;; esac
else
    [ -z "$SUBST_FROM" ] && [ "$SUBST_TO_SET" = 0 ] || die "--from/--to only make sense with --mode subst"
fi
for v in CAP_KB TIMEOUT_S MIN_FREE_MB MAX_DROP_MB; do
    eval "x=\$$v"
    case "$x" in ''|*[!0-9]*) die "--${v,,} must be a non-negative integer (got '$x')" ;; esac
done
[ -z "$PREDICT" ] || [ -r "$PREDICT" ] || die "--predict file not readable: $PREDICT"
[ -z "$LABELS_FROM" ] || [ -n "$PROVENANCE" ] || die "--labels-from only makes sense with --provenance"
[ -z "$LABELS_FROM" ] || [ -r "$LABELS_FROM" ] || die "--labels-from file not readable: $LABELS_FROM"

# Every git call drops an ambient GIT_DIR/GIT_WORK_TREE, as repo-root.sh does:
# an exported pair would redirect `-C` to a repository that is not the one
# under the directory named.
mg_git() { env -u GIT_DIR -u GIT_WORK_TREE git "$@"; }

if [ -n "$SUITE" ]; then
    SUITE_ABS=$(cd "$(dirname "$SUITE")" && pwd)/$(basename "$SUITE")
    SUITE_DIR=$(dirname "$SUITE_ABS")
fi

# ---------------------------------------------------------------------------
# SUBJECT MODE — resolve the repository both files live in (section 7).
#
# `git -C <dir>` on a directory that is not its own repository WALKS UP and
# answers about the enclosing one at rc 0 (CLAUDE.md, the walk-up trap). That
# is tolerable HERE for a stated reason, not by luck: the answer is used only
# as the root to COPY, and both the suite and the subject must then be found
# INSIDE that copy — a walked-up root whose ignore rules exclude them (every
# `work/<project>` under a nexus) yields a copy that lacks them, and that is a
# refusal below, not a wrong answer. `repo-root.sh` still gets the last word.
# ---------------------------------------------------------------------------
TOP=""; SUBJECT_ABS=""; SUBJ_REL=""; SUITE_REL=""
mg_resolve_top() {   # <abs path of a file> -> the PHYSICAL toplevel, or empty
    local d; d=$(cd "$(dirname "$1")" && pwd -P) || return 1
    mg_git -C "$d" rev-parse --show-toplevel 2>/dev/null
}
mg_rel() {   # <abs file> <top> -> repo-relative path, or empty when outside
    local d f; d=$(cd "$(dirname "$1")" && pwd -P) || return 1
    f="$d/$(basename "$1")"
    case "$f" in "$2"/*) printf '%s' "${f#"$2"/}" ;; *) printf '' ;; esac
}
if [ -n "$SUBJECT" ]; then
    [ -n "$SUITE" ] || die "--subject needs --suite: the subject is mutated, the SUITE is what is run against it"
    [ -r "$SUBJECT" ] && [ -f "$SUBJECT" ] || die "subject not a readable file: $SUBJECT"
    SUBJECT_ABS=$(cd "$(dirname "$SUBJECT")" && pwd -P)/$(basename "$SUBJECT")
    TOP=$(mg_resolve_top "$SUBJECT_ABS") || TOP=""
    [ -n "$TOP" ] || die "subject is not inside a git repository: $SUBJECT_ABS"
    SUBJ_REL=$(mg_rel "$SUBJECT_ABS" "$TOP")
    SUITE_REL=$(mg_rel "$SUITE_ABS" "$TOP")
    [ -n "$SUBJ_REL" ]  || die "subject resolves outside its own repository root ($TOP)"
    [ -n "$SUITE_REL" ] || die "the suite is not in the subject's repository ($TOP) — both arms run in a copy of ONE tree"
    [ "$SUBJ_REL" != "$SUITE_REL" ] || die "--subject and --suite are the same file; drop --subject to mutate the suite"
    # The logical-line predicate below is a SHELL predicate. Applied to Python
    # or awk it would pronounce lines safe on rules that do not hold there.
    # shellcheck source=shell-files.sh
    . "$_here/shell-files.sh"
    if ! shf_is_shell "$SUBJECT_ABS"; then
        printf 'mutation-gate.sh: REFUSED — the subject is not a SHELL file (class: %s).\n' "$(shf_class "$SUBJECT_ABS" 2>/dev/null || echo '?')" >&2
        printf '  The complete-logical-line predicate is a shell predicate; on another language it\n' >&2
        printf '  would call a line safe by rules that do not apply. No mutant was built.\n' >&2
        exit 3
    fi
    [ "$MATCH_SET" = 1 ] || MATCH='.'
elif [ -n "$SUITE" ] && [ -z "$RUN_BOUNDED" ]; then
    # Suite mode and --provenance want the suite's repo-relative name for the
    # ledger; outside any repository it stays the basename.
    TOP=$(mg_resolve_top "$SUITE_ABS") || TOP=""
    [ -z "$TOP" ] || SUITE_REL=$(mg_rel "$SUITE_ABS" "$TOP")
    [ -n "$SUITE_REL" ] || SUITE_REL=$(basename "$SUITE_ABS")
    case "$MODE" in if-true|if-false|subst) die "--mode $MODE needs --subject: a suite has no guard to weaken" ;; esac
fi
# The file whose line is mutated, and whose lines --list offers.
TARGET_ABS="${SUBJECT_ABS:-${SUITE_ABS:-}}"
# The workdir is OURS unless the caller named one, and ours is removed on
# EXIT. This trap is installed on the line after the allocation, not at the
# apply step 300 lines below where it used to live — that trap removed only
# the mutant COPY ($MUT), so every path out of this script, verdict or `die`,
# left `$TMPDIR/mutgate-$$` behind. Measured 2026-09-03: 4,006 such dirs on a
# tmpfs /tmp, accrued over six days, one per invocation, success paths included
# (96 of a 400-dir sample held a complete baseline+mutant capture set). A
# caller-supplied --workdir is kept — it asked for the captures — and so is
# ours under --keep-workdir, which prints the path so a reader can find it.
# BACKSTOP for a workdir whose run was SIGKILLed (your-org/nexus-code#1601).
# The EXIT trap below fires on TERM/INT/HUP (measured) but nothing survives
# KILL — `timeout -k`'s escalation, an OOM kill — and 1,098 `mutgate-*` sat in
# /tmp on 2026-09-21, all older than 24 h. Each run therefore removes OTHER
# runs' leftovers, and only what it can attribute on every axis:
#   name   exactly `mutgate-<pid>`; a real directory, never a symlink; this uid;
#   age    mtime older than 24 h (CHOSEN: the tmpfs-guard reap window);
#   owner  the pid in the name is NOT alive — a live pid may be the run, and a
#          recycled one cannot be told from it, so both are refused;
#   intent no `.kept` marker, which --keep-workdir writes: kept captures stay.
# The walk is bounded (10 s, CHOSEN) and a sweep that cannot finish removes
# nothing more; it never fails the gate.
mg_sweep_stale_workdirs() {
    local dir="${TMPDIR:-/tmp}" d base pid
    [ -d "$dir" ] || return 0
    while IFS= read -r -d '' d; do
        base=${d##*/}
        [[ "$base" =~ ^mutgate-([0-9]+)$ ]] || continue
        pid=${BASH_REMATCH[1]}
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        [ -e "$d/.kept" ] && continue
        kill -0 "$pid" 2>/dev/null && continue
        [ -d "/proc/$pid" ] && continue      # alive but not ours to signal: still alive
        rm -rf -- "$d" 2>/dev/null || true
    done < <(timeout -k 2 10 find "$dir" -mindepth 1 -maxdepth 1 -type d -name 'mutgate-*' \
                 -user "$(id -u)" -mmin +1440 -print0 2>/dev/null)
    return 0
}
mg_sweep_stale_workdirs
WORKDIR_OWNED=0
if [ -z "$WORKDIR" ]; then
    WORKDIR="${TMPDIR:-/tmp}/mutgate-$$"
    WORKDIR_OWNED=1
fi
mkdir -p "$WORKDIR" || die "cannot create workdir: $WORKDIR"
# ABSOLUTE, because the suite cd's wherever it likes and a relative fence would
# be resolved against each resolver's own cwd (your-org/nexus-code#1680).
MG_FENCE=$(cd "$WORKDIR" && pwd -P) && [ -n "$MG_FENCE" ] \
    || die "cannot resolve the workdir to an absolute path: $WORKDIR"
MUT=""
mg_cleanup() {
    [ -n "$MUT" ] && rm -f -- "$MUT"
    # The subject-mode tree copies are scaffolding, not captures: removed even
    # from a caller-named --workdir, unless the caller asked to keep everything.
    [ "$KEEP_WORKDIR" = 1 ] || rm -rf -- "${WORKDIR:?}/t0" "${WORKDIR:?}/t1" "${WORKDIR:?}/tmp"
    if [ "$WORKDIR_OWNED" = 1 ]; then
        if [ "$KEEP_WORKDIR" = 1 ]; then
            : > "$WORKDIR/.kept" 2>/dev/null   # exempts it from mg_sweep_stale_workdirs
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
    # THE SUITE'S TMPDIR IS OURS, NOT THE CALLER'S (your-org/nexus-code#1601).
    # A suite that stubs tmux leaves spawn-worker.sh's `spawn-prompt-*` and
    # `spawn-launcher-*` in ${TMPDIR:-/tmp} BY CONSTRUCTION: only the launcher
    # removes them, and a stubbed `send-keys` never runs it. run-tests.sh hands
    # every suite a private, reaped TMPDIR (#1481); this gate ran the suite TWICE
    # per invocation in the caller's, usually /tmp, and on 2026-09-21 /tmp held
    # 922 such files plus 1,098 `mutgate-*` — a depth-1 population that made
    # `tmpfs-guard.sh --check`, and so `svc.sh status`, stop returning.
    # ONE path for every run, deliberately: a per-run path would put a varying
    # string into any label that echoes a tmp path, and the label-keyed diff
    # below would read it as LOST+NEW. NOT emptied between runs, so the
    # free-space backstop still sees whatever the baseline and mutant wrote; it
    # goes with the workdir scaffolding in mg_cleanup. TMUX_TMPDIR is left alone
    # — its length budget is sun_path's, and it is not what leaked.
    # If it cannot be created the run falls back to the inherited TMPDIR: the
    # old leak, never a refused gate over scratch placement.
    local run_tmp="${TMPDIR:-/tmp}"
    mkdir -p "$WORKDIR/tmp" 2>/dev/null && run_tmp="$WORKDIR/tmp"
    # `ulimit -f` is in 1024-byte units on this bash (measured), and is an
    # RLIMIT, so it is inherited by every child and grandchild the mutant
    # spawns. `timeout` covers the hole `ulimit -f` cannot: a mutant writing to
    # a PIPE is not bounded by a file-size limit (measured).
    # `ulimit -c 0`: a mutant the file cap kills dies of SIGXFSZ, and SIGXFSZ
    # DUMPS CORE — into the CWD, i.e. the repository root. Measured on two clean
    # clones after a full band: an untracked 64 KB `core` "from 'yes yes'" in
    # each, and every later run-log header in those trees read `dirty=yes`.
    # THE TEST FENCE (your-org/nexus-code#1680). The copies (t0/t1) and the
    # suite's TMPDIR all live under $WORKDIR, and a --workdir under a nexus's
    # work/ made each of them "a nexus tree nested under a nexus's work/": the
    # copied tree took the PRIMARY's identity (every baseline red) and the
    # suite's fixture nexuses re-rooted onto the primary and wrote 321 rows into
    # its production action log. Under the fence, the primary-root resolvers
    # (monitor/_nexus-root.sh, spawn-worker.sh) never leave $WORKDIR.
    NEXUS_TEST_FENCE="$MG_FENCE" TMPDIR="$run_tmp" timeout -k 10 "$TIMEOUT_S" \
        bash -c 'ulimit -c 0; ulimit -f "$1" || exit 90; shift; exec bash "$@"' _ "$CAP_KB" "$script" \
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
    # The bare hand-rolled footer, `N passed, M failed` alone on a line — what
    # test-cc-auto-update.sh (the largest suite here) prints.
    [ -n "$n" ] || n=$(sed -n 's/^\([0-9][0-9]*\) passed, [0-9][0-9]* failed$/\1/p' "$f" | tail -1)
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
mg_eligible() {   # <file> [ifmode=0|1|2]   1 = the if-* modes, 2 = subst
    awk -v ifmode="${2:-0}" '
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

        # THE if-* MODES ASK A DIFFERENT QUESTION (section 7c). They do not
        # REMOVE the line, they rewrite its condition in place, so the line
        # need not END a logical line — it must be exactly one single-line
        # `if …; then` / `elif …; then`, whose structure survives the rewrite.
        # Everything else below still applies: a line the previous one
        # continues into, or one with unbalanced quoting, is not one condition.
        # SUBST (ifmode 2) rewrites text INSIDE a line and removes nothing. The
        # line may be any part of a multi-line construct — that is the point, a
        # compound condition spans lines — so none of the completeness rules
        # below apply to it. What must hold instead is that the rewrite leaves
        # the line'"'"'s STRUCTURE alone, and that is checked on the old and new
        # text together, at the apply step, where both exist.
        if (ok && ifmode == 2) { print NR "\t" "yes" "\t" ""; prev = s; next }
        if (ok && ifmode) {
            if (s !~ /^(if|elif)[ \t]+[^ \t].*;[ \t]*then$/) {
                ok = 0; reason = "not a single-line `if …; then` / `elif …; then` (the if-* modes rewrite one condition in place)"
            }
        }
        # The line itself must END a logical line.
        if (ok && !ifmode) {
            # BREAK on the first match, and the list is ordered LONGEST FIRST.
            # Without the break the LAST match won, so `&&` was reported as
            # `continuation token: &` — a correct refusal naming the wrong token,
            # which sends the reader looking for a construct that is not there.
            for (i = 1; i <= n_cont; i++)
                if (ends_with(s, cont[i])) { ok = 0; reason = "ends with a continuation token: " cont[i]; break }
        }
        # …and it must BEGIN one: the previous meaningful line must not have
        # continued into it. This is the rule that would have stopped #1032.
        # In the if-* modes only a BACKSLASH predecessor refuses: the line is
        # rewritten, never removed, so a block opener (`{`, `then`, `do`) or a
        # list operator above it promotes nothing — whereas after a backslash
        # the `if` is an ARGUMENT of the command above, not a condition.
        if (ok && prev != "") {
            for (i = 1; i <= n_cont; i++) {
                if (ifmode && cont[i] != "\\") continue
                if (ends_with(prev, cont[i])) { ok = 0; reason = "continues the previous line (which ends with " cont[i] ")"; break }
            }
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

# ---------------------------------------------------------------------------
# CASE LABELS, THE FLIP SET, THE PREDICTION, THE LEDGER (section 8).
# ---------------------------------------------------------------------------
# A case is a line `  PASS: <label>` — what `_test_helpers.sh` prints for every
# assertion, and what most hand-rolled suites print too. A suite that prints no
# such line has NO cases this tool can name; that is said, never papered over.
mg_labels() {   # <captured stdout> -> SORTED PASS labels, duplicates KEPT
    # A multiset on purpose: `comm` pairs duplicate lines, so a label printed
    # twice at baseline and once in the mutant still shows up as one loss.
    sed -n 's/^[[:space:]]*PASS: //p' "$1" | LC_ALL=C sort
}
# mg_flipset <base.out> <mut.out> <mut.err>
#   -> $WORKDIR/flipped    labels, one per line (what --predict and --record read)
#      $WORKDIR/flipped.ev the same, as `<evidence>\t<label>`
#      $WORKDIR/vanished   stopped passing, and NOTHING accounts for them
#      $WORKDIR/relabelled stopped printing that label; a near-identical PASS appeared
#      $WORKDIR/unmatched  FAIL lines that were paired with no case
#
# THE PRIMARY SIGNAL IS "STOPPED PASSING" — the multiset difference of the PASS
# labels — because it needs nothing from the FAIL text. The FAIL lines are the
# EVIDENCE for how each loss happened, in decreasing strength:
#
#   named    the mutant printed `FAIL: <that label>`, alone or followed by
#            ` — detail`. Every `_test_helpers.sh` assertion reports this way.
#   prefix   a FAIL line shares its LONGEST common prefix with that label —
#            uniquely, and at least 8 characters or the label's whole case id
#            (up to its first `:`). For suites whose `fail` text is
#            free-form — `pass "#1492 O1: under the cap …"` beside
#            `fail "#1492 O1: the bound fired early"` — the case id is the prefix.
#   count    no FAIL line names or prefixes it, but there are at least as many
#            unpaired FAIL lines as unexplained losses: every loss has a failure
#            to account for it, though not WHICH.
#
# and two outcomes that are NOT flips:
#
#   relabelled  a PASS label that embeds a VALUE (`pre-streak=2`) prints
#               different text in the mutant while still passing. Paired to the
#               new label by the same prefix rule.
#   vanished    stopped passing and nothing accounts for it: fewer FAIL lines
#               than losses, so the case most likely never RAN (an abort, a
#               conditional). Not a pass, and not a flip.
#
# `index(line, L " — ") == 1` rather than a substr() by length: the dash is
# multibyte, and awk counts bytes or characters depending on build and locale;
# a whole-string index is correct under both.
mg_flipset() {
    mg_labels "$1" > "$WORKDIR/base.labels.all"
    mg_labels "$2" > "$WORKDIR/mut.labels.all"
    LC_ALL=C sort -u "$WORKDIR/base.labels.all" > "$WORKDIR/base.labels"
    LC_ALL=C comm -23 "$WORKDIR/base.labels.all" "$WORKDIR/mut.labels.all" > "$WORKDIR/notpassed"
    LC_ALL=C comm -13 "$WORKDIR/base.labels.all" "$WORKDIR/mut.labels.all" > "$WORKDIR/newlabels"
    cat "$2" "$3" | sed -n 's/^[[:space:]]*FAIL: //p' > "$WORKDIR/mut.fails"
    : > "$WORKDIR/flipped.ev"; : > "$WORKDIR/vanished"; : > "$WORKDIR/relabelled"; : > "$WORKDIR/unmatched"
    awk -v F_EV="$WORKDIR/flipped.ev" -v F_VAN="$WORKDIR/vanished" \
        -v F_REL="$WORKDIR/relabelled" -v F_UNM="$WORKDIR/unmatched" '
        function cpl(a, b,   i, n) {
            n = (length(a) < length(b)) ? length(a) : length(b)
            for (i = 1; i <= n; i++) if (substr(a, i, 1) != substr(b, i, 1)) break
            return i - 1
        }
        # pair(src, nsrc, used, tag): pair src lines with still-unexplained
        # losses by longest common prefix, GLOBALLY BEST FIRST.
        #
        # Not "each src line takes its best loss, in file order". That greedy
        # form was the first cut, and the first real run CROSS-PAIRED two cases:
        # `#1113: a PR under active review…` got the FAIL line of
        # `#1113: an unparseable updated-at…` and vice versa, because the FAIL
        # that came first shared 10 characters with the WRONG label and 8 with
        # its own, and took the 10. The flip SET was right; the evidence printed
        # beside it named the wrong failure. Taking the longest pair anywhere
        # first gives `…an unparseable` its 22-character match before the
        # 8-character one is considered.
        #
        # ENOUGH PREFIX: 8 characters, or the label'"'"'s whole case id when that is
        # shorter — everything up to and including its first `:` (`FF-O1:`), which
        # is what a suite with free-form FAIL text keeps constant between its
        # `pass` and its `fail`. A top pair TIED with another pair that shares its
        # src line or its label is AMBIGUOUS: that src line is left unpaired (it
        # still counts toward the COUNT evidence) rather than guessed.
        function pair(src, nsrc, used, tag,   j, i, c, best, bj, bi, tie, need, t, skip) {
            while (1) {
                best = 0; bj = 0; bi = 0
                for (j = 1; j <= nsrc; j++) {
                    if (used[j] || skip[j]) continue
                    for (i = 1; i <= nnp; i++) {
                        if (ev[i] != "") continue
                        c = cpl(src[j], np[i])
                        if (c > best) { best = c; bj = j; bi = i }
                    }
                }
                if (!bj) break
                need = 8; t = index(np[bi], ":"); if (t >= 3 && t < 8) need = t
                if (best < need) break
                tie = 0
                for (j = 1; j <= nsrc; j++) {
                    if (used[j] || skip[j]) continue
                    for (i = 1; i <= nnp; i++) {
                        if (ev[i] != "" || (j == bj && i == bi)) continue
                        if ((j == bj || i == bi) && cpl(src[j], np[i]) == best) tie = 1
                    }
                }
                if (tie) { skip[bj] = 1; continue }
                ev[bi] = tag; with[bi] = src[bj]; used[bj] = 1
            }
        }
        FILENAME == ARGV[1] { np[++nnp] = $0; next }
        FILENAME == ARGV[2] { fl[++nfl] = $0; next }
        FILENAME == ARGV[3] { nw[++nnw] = $0; next }
        END {
            for (i = 1; i <= nnp; i++)
                for (j = 1; j <= nfl; j++)
                    if (!fu[j] && (fl[j] == np[i] || index(fl[j], np[i] " — ") == 1)) { ev[i] = "named"; fu[j] = 1; break }
            pair(fl, nfl, fu, "prefix")
            pair(nw, nnw, nu, "relabelled")
            rem_np = 0; for (i = 1; i <= nnp; i++) if (ev[i] == "") rem_np++
            rem_fl = 0; for (j = 1; j <= nfl; j++) if (!fu[j]) rem_fl++
            if (rem_np > 0 && rem_fl >= rem_np) {
                for (i = 1; i <= nnp; i++) if (ev[i] == "") ev[i] = "count"
                for (j = 1; j <= nfl; j++) fu[j] = 1
            }
            for (i = 1; i <= nnp; i++) {
                if (ev[i] == "relabelled")  print np[i] "\t" with[i] > F_REL
                else if (ev[i] == "")       print np[i] > F_VAN
                else                        print ev[i] "\t" np[i] "\t" with[i] > F_EV
            }
            for (j = 1; j <= nfl; j++) if (!fu[j]) print fl[j] > F_UNM
        }' "$WORKDIR/notpassed" "$WORKDIR/mut.fails" "$WORKDIR/newlabels"
    cut -f2 "$WORKDIR/flipped.ev" | LC_ALL=C sort -u > "$WORKDIR/flipped"
}
mg_print_flipset() {
    local n_f n_v n_u n_r ev label with
    n_f=$(grep -c . "$WORKDIR/flipped.ev"); n_v=$(grep -c . "$WORKDIR/vanished")
    n_u=$(grep -c . "$WORKDIR/unmatched");  n_r=$(grep -c . "$WORKDIR/relabelled")
    printf '  flip set — %s case(s) PASSED at baseline and did not in the mutant:\n' "$n_f"
    while IFS=$'\t' read -r ev label with; do
        case "$ev" in
            named)  printf '    FLIPPED: %s\n' "$label" ;;
            prefix) printf '    FLIPPED: %s\n               [paired by PREFIX with: FAIL: %s]\n' "$label" "$with" ;;
            count)  printf '    FLIPPED: %s\n               [by COUNT only: as many unpaired FAIL lines as unexplained losses]\n' "$label" ;;
        esac
    done < "$WORKDIR/flipped.ev"
    if [ "$n_r" -gt 0 ]; then
        printf '  %s case(s) changed their LABEL and still pass (a value embedded in the text):\n' "$n_r"
        while IFS=$'\t' read -r label with; do printf '    RELABELLED: %s\n                -> %s\n' "$label" "$with"; done < "$WORKDIR/relabelled"
    fi
    if [ "$n_v" -gt 0 ]; then
        printf '  %s case(s) stopped passing and NOTHING accounts for them — most likely they never RAN (not a pass, not a flip):\n' "$n_v"
        sed 's/^/    VANISHED: /' "$WORKDIR/vanished"
    fi
    if [ "$n_u" -gt 0 ]; then
        printf '  %s FAIL line(s) were paired with no baseline case:\n' "$n_u"
        sed 's/^/    UNMATCHED: /' "$WORKDIR/unmatched"
    fi
}
# mg_predict_check -> rc 0 refutes nothing, rc 1 REFUTED; prints one line per prediction.
PREDICTION_STATE=none
PREDICT_SHA='-'
# THE PREDICTION IS SNAPSHOTTED BEFORE EITHER ARM RUNS, AND ONLY THE SNAPSHOT
# IS EVER READ (skeptic finding F1 on #1558). The first cut re-read the file
# from disk after the mutant arm, so a prediction rewritten mid-run was
# reported "registered before the run … confirmed" and recorded as such — the
# pre-registration the ledger column claims was not enforced by anything.
# Before EITHER arm, not merely before the mutant: the suite under test can
# write files, and a suite that rewrote its own prediction during the baseline
# arm would otherwise be validated against the rewrite. The snapshot's blob
# hash is printed and recorded (ledger column 13), so a row can be checked
# against the file an author kept.
# AND THE SNAPSHOT IS HELD IN MEMORY, NOT READ BACK FROM THE WORKDIR (skeptic
# round 2, G1). The first snapshot was a FILE under $WORKDIR — the directory
# the suite's tree copies live in — so a suite that wrote `../../predict.snap`
# turned a wrong prediction into "confirmed", and the tool then blamed the
# author's file for having changed. A hash that is not BOUND to what is
# evaluated is a caption. So: the content lives in a variable from the moment
# it is taken; the file copy exists only so the run can be audited afterwards;
# and if that file no longer hashes to the recorded blob at finish, something
# wrote into this tool's own workdir during the run — the run is REFUSED, not
# scored. A failed hash is a refusal too: `-` would be an unauditable row
# wearing a column's name.
# READ THE FILE ONCE (skeptic round 3, G8). The G1 fix read `--predict` TWICE
# — `grep` for the text, then `cp` for the file that gets hashed — so the hash
# bound the SECOND read while the verdict used the first. With a process
# substitution or a FIFO those are different bytes: measured, `--predict
# <(printf …)` scored "confirmed" beside the EMPTY blob, and a FIFO fed the
# right prediction then a wrong one scored "confirmed" beside the wrong one's
# blob — round-2's artefact, reached by a new path. So: ONE copy, and both the
# text and the hash come from that copy. An EMPTY copy is refused here: the
# vacuity refusal downstream would catch it too, but a zero-byte snapshot is a
# registration that registered nothing, and saying so at the source is cheaper.
PREDICT_TEXT=""
mg_predict_snapshot() {
    cp -- "$PREDICT" "$WORKDIR/predict.snap" || die "cannot snapshot --predict file $PREDICT"
    if [ ! -s "$WORKDIR/predict.snap" ]; then
        printf 'mutation-gate.sh: REFUSED — the --predict snapshot is EMPTY (%s read as zero bytes); a prediction that registers nothing cannot be recorded as pre-registered.\n' "$PREDICT" >&2
        exit 3
    fi
    PREDICT_TEXT=$(grep -v -E '^[[:space:]]*(#|$)' -- "$WORKDIR/predict.snap") || PREDICT_TEXT=""
    PREDICT_SHA=$(mg_git hash-object -- "$WORKDIR/predict.snap" 2>/dev/null) || PREDICT_SHA=""
    [[ "$PREDICT_SHA" =~ ^[0-9a-f]{40}$ ]] || {
        printf 'mutation-gate.sh: REFUSED — could not hash the --predict snapshot (%s); a prediction that cannot be bound to a blob cannot be recorded as pre-registered.\n' "$PREDICT" >&2
        exit 3
    }
}
mg_predict_lines() { printf '%s\n' "$PREDICT_TEXT" | grep -v -E '^[[:space:]]*$'; }
# mg_predict_intact -> rc 0, or REFUSES (exit 3) when the snapshot file no
# longer hashes to the blob recorded before the run.
mg_predict_intact() {
    local now
    now=$(mg_git hash-object -- "$WORKDIR/predict.snap" 2>/dev/null) || now=""
    [ "$now" = "$PREDICT_SHA" ] && return 0
    printf 'mutation-gate.sh: REFUSED — the prediction SNAPSHOT in this tool'"'"'s workdir was altered during the run (blob %s at registration, %s now).\n' "$PREDICT_SHA" "${now:-unhashable}" >&2
    printf '  Something the run executed wrote into %s. The verdict was computed but is NOT\n' "$WORKDIR" >&2
    printf '  scored and NOT recorded: a run that can reach the instrument'"'"'s own state is not\n' >&2
    printf '  a run whose prediction outcome means anything (skeptic G1 on #1558).\n' >&2
    exit 3
}
mg_predict_validate() {   # every line must name a baseline case, BEFORE the mutant runs
    local line sign text n_minus=0
    # AN EMPTY PREDICTION IS REFUSED, NOT VALIDATED VACUOUSLY (your-org/nexus-code
    # #1564 G12). Validation below is PER LINE, so a file of comments and blanks
    # — non-empty on disk, which is all the snapshot check sees — validated with
    # zero iterations, and on a SURVIVING mutant `mg_predict_check` then found
    # nothing refuted and the ledger recorded `survived … confirmed`: a
    # pre-registered prediction that predicted nothing, scored as correct.
    if [ -z "$(mg_predict_lines)" ]; then
        printf 'mutation-gate.sh: REFUSED — the --predict file holds NO prediction lines (only comments/blanks).\n' >&2
        printf '  Every LINE is validated, so an empty prediction validates vacuously and a surviving\n' >&2
        printf '  mutant then scores `confirmed`. Write at least one `+label` or `-label` (#1564 G12).\n' >&2
        return 3
    fi
    while IFS= read -r line; do
        sign=${line:0:1}; text=${line:1}
        case "$sign" in
            +) ;;
            -) n_minus=$((n_minus+1)) ;;
            *) printf 'mutation-gate.sh: REFUSED — --predict line is neither `+text` nor `-text`: %s\n' "$line" >&2; return 3 ;;
        esac
        [ -n "$text" ] || { printf 'mutation-gate.sh: REFUSED — --predict line has an EMPTY label (it would match every case): %s\n' "$line" >&2; return 3; }
        if ! grep -qF -- "$text" "$WORKDIR/base.labels"; then
            printf 'mutation-gate.sh: REFUSED — --predict line names NO baseline case: %s\n' "$line" >&2
            printf '  A prediction about a case that does not exist is vacuous: `-text` would be\n' >&2
            printf '  "confirmed" by an absence. The baseline printed %s case label(s).\n' "$(grep -c . "$WORKDIR/base.labels")" >&2
            return 3
        fi
    done < <(mg_predict_lines)
    if [ "$n_minus" -eq 0 ]; then
        printf '  NOTE: the prediction names no case that must NOT flip. A round that kills\n'
        printf '        everything is as uninformative as one that kills nothing (#1519).\n'
    fi
    return 0
}
mg_predict_check() {
    local line sign text refuted=0
    while IFS= read -r line; do
        sign=${line:0:1}; text=${line:1}
        if [ "$sign" = + ]; then
            if grep -qF -- "$text" "$WORKDIR/flipped"; then printf '    confirmed  %s\n' "$line"
            else printf '    REFUTED    %s  (predicted to flip; did not)\n' "$line"; refuted=1; fi
        else
            if grep -qF -- "$text" "$WORKDIR/flipped"; then
                printf '    REFUTED    %s  (predicted NOT to flip; it did)\n' "$line"; refuted=1
            elif grep -qF -- "$text" "$WORKDIR/vanished"; then
                printf '    REFUTED    %s  (predicted NOT to flip; it NEVER RAN in the mutant, so it was not evaluated)\n' "$line"; refuted=1
            else printf '    confirmed  %s\n' "$line"; fi
        fi
    done < <(mg_predict_lines)
    # THE PREDICTION IS OF A SET, SO IT IS EXHAUSTIVE. A flipped case that no `+`
    # line covers is a member the author did not foresee — and it was measured
    # on this tool's own first dogfood round: four cases flipped, two were named,
    # and a lenient check printed `confirmed` over a model that was half wrong.
    local label covered
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        covered=0
        while IFS= read -r line; do
            [ "${line:0:1}" = + ] || continue
            case "$label" in *"${line:1}"*) covered=1; break ;; esac
        done < <(mg_predict_lines)
        if [ "$covered" = 0 ]; then printf '    UNPREDICTED  %s  (flipped; no `+` line names it)\n' "$label"; refuted=1; fi
    done < "$WORKDIR/flipped"
    return "$refuted"
}
# mg_finish <verdict-rc> — the prediction and the ledger, then exit. EVERY
# verdict that was actually rendered leaves through here; refusals do not.
mg_blob() { [ -f "$1" ] && mg_git hash-object -- "$1" 2>/dev/null || printf '%s' '-'; }
mg_finish() {
    local rc="$1" verdict="$2" head_sha label
    if [ -n "$PREDICT" ]; then
        mg_predict_intact
        printf 'PREDICTION (registered before the run: %s, snapshot blob %s):\n' "$PREDICT" "$PREDICT_SHA"
        if [ -f "$PREDICT" ] && [ "$(mg_git hash-object -- "$PREDICT" 2>/dev/null)" != "$PREDICT_SHA" ]; then
            printf '  NOTE: %s CHANGED while the run was in progress. The snapshot taken before either\n' "$PREDICT"
            printf '        arm ran is what was evaluated and recorded; the file on disk is not.\n'
        fi
        if mg_predict_check; then PREDICTION_STATE=confirmed; printf '  PREDICTION: confirmed\n'
        else PREDICTION_STATE=refuted; printf '  PREDICTION: REFUTED — the verdict above stands; the model of the suite did not.\n'; fi
    else
        printf '  no --predict was registered before this run: a survivor (or a kill) is\n'
        printf '  trivially rationalised after the fact. Write the flip set down FIRST.\n'
    fi
    if [ -n "$RECORD" ]; then
        head_sha=$( [ -n "$TOP" ] && mg_git -C "$TOP" rev-parse HEAD 2>/dev/null || printf '%s' '-')
        if [ ! -s "$RECORD" ]; then
            printf '# mutation provenance ledger (your-org/nexus-code#1510). Append-only; written by\n# monitor/mutation-gate.sh --record, read by --provenance. One row per FLIPPED case.\n' >> "$RECORD"
            printf '# utc\tverdict\tsuite\tsuite_blob\tsubject\tsubject_blob\tline\tmode\tline_text\tcase\thead\tprediction\tpredict_blob\n' >> "$RECORD"
        fi
        mg_record_row() {
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$verdict" "$SUITE_REL" "$(mg_blob "$SUITE_ABS")" \
                "${SUBJ_REL:--}" "$( [ -n "$SUBJECT_ABS" ] && mg_blob "$SUBJECT_ABS" || printf '%s' '-')" \
                "$LINE" "$MODE" "$(sed -n "${LINE}p" "$TARGET_ABS" | tr '\t' ' ' | sed -E 's/^ +//')" \
                "$1" "$head_sha" "$PREDICTION_STATE" "$PREDICT_SHA" >> "$RECORD"
        }
        if [ "$verdict" = killed-by-assertion ] && [ -s "$WORKDIR/flipped" ]; then
            while IFS= read -r label; do mg_record_row "$label"; done < "$WORKDIR/flipped"
        else
            # A survivor, or a kill no case label accounts for: recorded, against
            # NO case (`-`), so "this line was tried and killed nothing" is on file.
            mg_record_row '-'
        fi
        printf '  recorded to %s\n' "$RECORD"
    fi
    [ "$PREDICTION_STATE" = refuted ] && exit 6
    exit "$rc"
}

# Taken HERE — after the workdir exists and before any arm, the --provenance
# run included, runs.
[ -z "$PREDICT" ] || mg_predict_snapshot

# ---------------------------------------------------------------------------
# --provenance TSV --suite S [--labels-from F]   (section 8)
# ---------------------------------------------------------------------------
if [ -n "$PROVENANCE" ]; then
    [ -r "$PROVENANCE" ] || { printf 'mutation-gate.sh: REFUSED — provenance ledger not readable: %s\n' "$PROVENANCE" >&2; exit 3; }
    if [ -n "$LABELS_FROM" ]; then
        cp -- "$LABELS_FROM" "$WORKDIR/prov.out"
    else
        echo "=== running $SUITE_ABS once to read its CURRENT cases ==="
        prov_rc=$(mg_run "$SUITE_ABS" "$WORKDIR/prov")
        if [ "$prov_rc" -ne 0 ]; then
            printf 'mutation-gate.sh: REFUSED — the suite did not run green (rc %s); its case list is not trustworthy.\n' "$prov_rc" >&2
            exit 3
        fi
    fi
    mg_labels "$WORKDIR/prov.out" | LC_ALL=C sort -u > "$WORKDIR/prov.labels"
    n_cases=$(grep -c . "$WORKDIR/prov.labels")
    if [ "$n_cases" -eq 0 ]; then
        printf 'mutation-gate.sh: REFUSED — the suite printed no `PASS: <label>` line, so it has no case this tool can name.\n' >&2
        exit 3
    fi
    cur_suite_blob=$(mg_blob "$SUITE_ABS")
    n_guarded=0; n_stale=0; n_never=0
    while IFS= read -r label; do
        # The newest killing row for (suite, case). Tab-separated; `case` is
        # column 10. Matched by EQUALITY on both keys, never by pattern.
        row=$(awk -F'\t' -v s="$SUITE_REL" -v c="$label" \
              '$0 !~ /^#/ && $2 == "killed-by-assertion" && $3 == s && $10 == c { r = $0 } END { if (r != "") print r }' "$PROVENANCE")
        if [ -z "$row" ]; then
            printf 'NEVER-KILLED   %s\n' "$label"; n_never=$((n_never+1)); continue
        fi
        IFS=$'\t' read -r r_utc _ _ r_sblob r_subj r_jblob r_line r_mode _ _ _ _ <<<"$row"
        cur_subj_blob='-'
        [ "$r_subj" = '-' ] || cur_subj_blob=$(mg_blob "$TOP/$r_subj")
        if [ "$r_sblob" = "$cur_suite_blob" ] && [ "$r_jblob" = "$cur_subj_blob" ]; then
            printf 'GUARDED        %s   [%s %s:%s %s]\n' "$label" "$r_utc" "$r_subj" "$r_line" "$r_mode"; n_guarded=$((n_guarded+1))
        else
            printf 'GUARDED-STALE  %s   [%s %s:%s %s — the %s changed since]\n' "$label" "$r_utc" "$r_subj" "$r_line" "$r_mode" \
                "$( [ "$r_sblob" != "$cur_suite_blob" ] && [ "$r_jblob" != "$cur_subj_blob" ] && printf 'suite AND subject' \
                    || { [ "$r_sblob" != "$cur_suite_blob" ] && printf 'suite' || printf 'subject'; } )"
            n_stale=$((n_stale+1))
        fi
    done < "$WORKDIR/prov.labels"
    printf '=== provenance: %s case(s) — %s GUARDED, %s GUARDED-STALE, %s NEVER-KILLED (ledger %s) ===\n' \
        "$n_cases" "$n_guarded" "$n_stale" "$n_never" "$PROVENANCE"
    printf '    GREEN is not GUARDED: a NEVER-KILLED case passes and has never been shown able to fail (#1510).\n'
    [ "$n_stale" -eq 0 ] && [ "$n_never" -eq 0 ] && exit 0
    exit 4
fi

if [ "$DO_LIST" -eq 1 ]; then
    printf '# eligible mutation candidates in %s\n' "$TARGET_ABS"
    printf '# (a line is listed only if it matches --match AND is a complete logical line)\n'
    n=0
    while IFS=$'\t' read -r ln verdict reason; do
        [ "$verdict" = yes ] || continue
        text=$(sed -n "${ln}p" "$TARGET_ABS")
        grep -qE "$MATCH" <<<"$text" || continue
        printf '%s\t%s\n' "$ln" "$text"; n=$((n+1))
    done < <(mg_eligible "$TARGET_ABS")
    printf '# %d eligible line(s)\n' "$n"
    n_if=0
    if [ -n "$SUBJECT_ABS" ]; then
        printf '# single-line `if`/`elif` conditions (--mode if-true | if-false):\n'
        while IFS=$'\t' read -r ln verdict reason; do
            [ "$verdict" = yes ] || continue
            printf '%s\t%s\n' "$ln" "$(sed -n "${ln}p" "$TARGET_ABS")"; n_if=$((n_if+1))
        done < <(mg_eligible "$TARGET_ABS" 1)
        printf '# %d if-line(s)\n' "$n_if"
    fi
    [ $(( n + n_if )) -gt 0 ] || { printf 'mutation-gate.sh: REFUSED — no eligible line (a zero here is a MEASURED answer, not a green light).\n' >&2; exit 3; }
    exit 0
fi

[ -n "$LINE" ] || die "--line is required (or --list)"
case "$LINE" in ''|*[!0-9]*) die "--line must be an integer" ;; esac

TOTAL=$(wc -l < "$TARGET_ABS")
[ "$LINE" -ge 1 ] && [ "$LINE" -le "$TOTAL" ] || die "--line $LINE is outside 1..$TOTAL"

# ---------------------------------------------------------------------------
# ELIGIBILITY — refuse before anything is written. Judged on the ORIGINAL
# target (the suite, or the subject under --subject), never on a copy.
# ---------------------------------------------------------------------------
IFMODE=0; case "$MODE" in if-true|if-false) IFMODE=1 ;; subst) IFMODE=2 ;; esac
elig=$(mg_eligible "$TARGET_ABS" "$IFMODE" | awk -F'\t' -v L="$LINE" '$1==L{print $2 "\t" $3}')
if [ "${elig%%$'\t'*}" != yes ]; then
    printf 'mutation-gate.sh: REFUSED — line %s of %s is not safely mutable (mode=%s).\n' "$LINE" "$TARGET_ABS" "$MODE" >&2
    printf '  reason : %s\n' "${elig#*$'\t'}" >&2
    printf '  line   : %s\n' "$(sed -n "${LINE}p" "$TARGET_ABS")" >&2
    printf '  why    : commenting a line that does not END a logical line promotes the NEXT\n' >&2
    printf '           line to a standalone command. One such mutant synthesized `yes yes`\n' >&2
    printf '           and filled a shared 378 GB tmpfs (your-org/nexus-code#1032).\n' >&2
    if [ -n "$SUBJECT_ABS" ]; then
        printf '           A comment or blank line changes nothing, and a green after it means nothing.\n' >&2
        printf '  next   : %s --suite %q --subject %q --list\n' "$0" "$SUITE_ABS" "$SUBJECT_ABS" >&2
    else
        printf '  next   : %s --suite %q --list\n' "$0" "$SUITE_ABS" >&2
    fi
    exit 3
fi

# SUBST: build the new line and REFUSE unless it provably has the old line's
# structure. The `#1032` hazard needs a line to disappear or to change how it
# joins its neighbours; so the rewrite must keep the first and last word, and
# must keep the COUNT of every character that opens, closes, quotes, joins or
# continues. That is deliberately STRICT — `&&` -> `||` is refused — because a
# refusal costs a reworded mutant and an acceptance could cost the node.
# Judged HERE, on the text alone, before a tree is copied or a baseline run: a
# refusal knowable from two strings must not cost two suite runs.
# The classic operators pass: `>=` -> `>`, `-ge` -> `-gt`, a name -> a literal.
SUBST_NEW=""
if [ "$MODE" = subst ]; then
    subst_old=$(sed -n "${LINE}p" "$TARGET_ABS")
    subst_refuse() {
        printf 'mutation-gate.sh: REFUSED — --mode subst on line %s: %s\n' "$LINE" "$1" >&2
        printf '  line   : %s\n  --from : %s\n  --to   : %s\n' "$subst_old" "$SUBST_FROM" "$SUBST_TO" >&2
        exit 3
    }
    case "$subst_old" in *"$SUBST_FROM"*) ;; *) subst_refuse "the --from text does not occur on the line" ;; esac
    subst_pre=${subst_old%%"$SUBST_FROM"*}; subst_suf=${subst_old#*"$SUBST_FROM"}
    case "$subst_suf" in *"$SUBST_FROM"*) subst_refuse "the --from text occurs MORE THAN ONCE; which one is the mutant?" ;; esac
    # Assembled by concatenation, never `${old/from/to}`: under bash 5.2's
    # patsub_replacement an `&` in the replacement is the MATCH, not a literal.
    SUBST_NEW="$subst_pre$SUBST_TO$subst_suf"
    [ "$SUBST_NEW" != "$subst_old" ] || subst_refuse "--to equals --from; the mutant would be inert"
    subst_words() { awk '{ print $1 "\t" $NF }' <<<"$1"; }
    [ "$(subst_words "$subst_old")" = "$(subst_words "$SUBST_NEW")" ] \
        || subst_refuse "the rewrite changes the line's FIRST or LAST word (what it is, or how it joins the next line)"
    # `$` is deliberately NOT here: it opens nothing on its own (`$(` is caught by
    # `(`, `${` by `{`, `$'` by `'`), and a name -> literal rewrite drops one.
    for subst_ch in '"' "'" '`' '(' ')' '{' '}' '[' ']' '\' ';' '&' '|' '<' '>' '#'; do
        subst_a=${subst_old//[!"$subst_ch"]/}; subst_b=${SUBST_NEW//[!"$subst_ch"]/}
        [ "${#subst_a}" -eq "${#subst_b}" ] \
            || subst_refuse "the rewrite changes how many \`$subst_ch\` the line carries (${#subst_a} -> ${#subst_b}); its structure would not be the old line's"
    done
fi

# ---------------------------------------------------------------------------
# SUBJECT MODE: build the two throwaway trees (section 7a) and plant the load
# witness (7b). Suite mode runs the tracked suite in place, as it always has.
# ---------------------------------------------------------------------------
BASE_SCRIPT="$SUITE_ABS"      # what the baseline arm executes
WITNESS_OFF=0                 # lines the witness pushed the subject down by
T0=""; T1=""
if [ -n "$SUBJECT_ABS" ]; then
    # The verdict line is kept WHATEVER the rc: repo-root.sh exits 1 on every
    # `verdict=no`, and `|| rr=""` here threw its answer away — so a linked
    # worktree, which it names correctly, was reported as "gave no answer".
    rr=$(bash "$_here/repo-root.sh" "$TOP" 2>/dev/null); : "rc $? is carried by the verdict line"
    # A LINKED WORKTREE IS ACCEPTED (skeptic round 3, infra note). repo-root.sh
    # answers `verdict=no kind=linked-worktree` for one, correctly for ITS
    # question — the git dir belongs to the main repository, so a write there
    # would land elsewhere. THIS tool only reads the working tree (`ls-files`
    # runs fine in a worktree) and never writes to the git dir, so that kind is
    # a legitimate root here and the workaround of a fresh clone is not needed.
    # THE KIND IS ASKED FOR, not globbed out of the verdict line (#1564 G13). That
    # line also carries `top=` and `gitdir=` PATHS, so `*kind=linked-worktree*`
    # accepted any refused tree whose path merely contained the text.
    # `repo-root.sh --kind` prints the one field; both accepting tests below are
    # EQUALITY on a field, so no input matches an accept and the refusal (#1121).
    rr_kind=$(bash "$_here/repo-root.sh" --kind "$TOP" 2>/dev/null); : "rc $? is carried by the kind"
    rr_ok=0
    case "$rr" in "verdict=yes "*) rr_ok=1 ;; esac
    [ "$rr_kind" = linked-worktree ] && rr_ok=1
    if [ "$rr_ok" -ne 1 ]; then
        printf 'mutation-gate.sh: REFUSED — %s is not its own repository root (%s).\n' "$TOP" "${rr:-repo-root.sh gave no answer}" >&2
        printf '  The tree to copy could not be established; no mutant was built.\n' >&2
        exit 3
    fi
    # Short, EQUAL-LENGTH names: the arms must not differ in path length, which
    # a suite binding a socket under its own tree would feel.
    T0="$WORKDIR/t0"; T1="$WORKDIR/t1"
    mkdir -p "$T0" || die "cannot create $T0"
    # WORKING-TREE content of every tracked and untracked-unignored file. tar,
    # not a cp loop: ~1000 files, one process. `--ignore-failed-read` because a
    # tracked file DELETED in the working tree is listed and is not there.
    if ! ( cd "$TOP" && mg_git ls-files -co --exclude-standard -z \
             | tar --null --ignore-failed-read -T - -cf - 2>"$WORKDIR/tar.err" ) \
         | tar -xf - -C "$T0" 2>>"$WORKDIR/tar.err"; then
        printf 'mutation-gate.sh: REFUSED — could not copy the working tree of %s:\n' "$TOP" >&2
        tail -n 5 "$WORKDIR/tar.err" >&2
        exit 3
    fi
    if [ ! -f "$T0/$SUBJ_REL" ] || [ ! -f "$T0/$SUITE_REL" ]; then
        printf 'mutation-gate.sh: REFUSED — the copy of %s lacks the %s.\n' "$TOP" \
            "$( [ -f "$T0/$SUBJ_REL" ] && printf 'suite (%s)' "$SUITE_REL" || printf 'subject (%s)' "$SUBJ_REL" )" >&2
        printf '  Only tracked and untracked-UNIGNORED files are copied; a gitignored path is\n' >&2
        printf '  not (and a walked-up repository root ignores every tree beneath it).\n' >&2
        exit 3
    fi
    n_ignored=$(cd "$TOP" && mg_git status --porcelain --ignored 2>/dev/null | grep -c '^!!')
    printf '  tree   : %s copied (%s files); %s gitignored path(s) NOT copied — a sub-check\n' \
        "$TOP" "$(cd "$T0" && find . -type f | grep -c .)" "$n_ignored"
    printf '           gated on one skips in BOTH arms and cannot flip (false SURVIVORS only).\n'
    # THE LOAD WITNESS. One line, identical in both arms. After a shebang when
    # there is one — line 1 must stay the interpreter line — else at the top;
    # either way it lands where a new logical line begins.
    if [ "$LOAD_WITNESS" = 1 ]; then
        # `echo x`, not `: >>`: an append of NOTHING leaves a zero-byte file, and the
        # check below is `-s`. A builtin, so it costs no fork in a hot subject.
        wline=$(printf 'echo x >> %q' "$WORKDIR/witness")
        if [ "$(head -c 2 "$T0/$SUBJ_REL")" = '#!' ]; then
            awk -v w="$wline" 'NR==1{print; print w; next} {print}' "$T0/$SUBJ_REL" > "$WORKDIR/subj.inst"
        else
            awk -v w="$wline" 'NR==1{print w} {print}' "$T0/$SUBJ_REL" > "$WORKDIR/subj.inst"
        fi
        if [ "$(( $(wc -l < "$T0/$SUBJ_REL") + 1 ))" -ne "$(wc -l < "$WORKDIR/subj.inst")" ]; then
            printf 'mutation-gate.sh: REFUSED — planting the load witness did not add exactly one line.\n' >&2; exit 3
        fi
        cat "$WORKDIR/subj.inst" > "$T0/$SUBJ_REL"    # cat, not mv: keep the mode bits
        WITNESS_OFF=1
    fi
    # Its own repository, so `git ls-files` in a population guard answers about
    # the COPY. `-c` for identity and hooks: NEVER the operator's global config
    # (#1244), and no hook of theirs runs on a throwaway commit.
    if ! ( cd "$T0" && mg_git init -q . \
             && mg_git add -A . \
             && mg_git -c user.name=mutation-gate -c user.email=mutation-gate@invalid \
                       -c core.hooksPath=/dev/null -c commit.gpgsign=false \
                       commit -q -m 'mutation-gate: throwaway copy' ) >"$WORKDIR/init.out" 2>&1; then
        printf 'mutation-gate.sh: REFUSED — could not make the tree copy a repository:\n' >&2
        tail -n 5 "$WORKDIR/init.out" >&2
        exit 3
    fi
    cp -a "$T0" "$T1" || die "cannot copy $T0 to $T1"
    BASE_SCRIPT="$T0/$SUITE_REL"
fi

# ---------------------------------------------------------------------------
# THE BOUND (2) — one runner, used for the baseline AND the mutant, so the two
# are comparable and the baseline proves the bound does not itself redden a
# healthy suite.
# ---------------------------------------------------------------------------
free_before=$(free_mb)

echo "=== baseline: $BASE_SCRIPT (unmutated) ==="
: > "$WORKDIR/witness"
base_rc=$(mg_run "$BASE_SCRIPT" "$WORKDIR/baseline")
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
mg_labels "$WORKDIR/baseline.out" > "$WORKDIR/base.labels"

# THE INERT-MUTANT REFUSAL (section 7b), at the EARLIEST point the truth is
# known: the baseline ran green and never executed this copy of the subject, so
# the mutant arm could only ever report `survived` about a file the suite does
# not read. Refused BEFORE the mutant is built.
if [ -n "$SUBJECT_ABS" ] && [ "$LOAD_WITNESS" = 1 ] && [ ! -s "$WORKDIR/witness" ]; then
    printf 'mutation-gate.sh: REFUSED — the suite ran GREEN and NEVER EXECUTED the copy of the subject.\n' >&2
    printf '  subject: %s   (copy: %s)\n' "$SUBJ_REL" "$T0/$SUBJ_REL" >&2
    printf '  A mutation there would be INERT, and an inert mutant reads exactly like a\n' >&2
    printf '  survivor. Either this suite does not exercise this subject at all, or it\n' >&2
    printf '  resolves it from somewhere else — an exported NEXUS_ROOT (currently: %s), an\n' "${NEXUS_ROOT:-unset}" >&2
    printf '  absolute path, an installed copy. If the suite reads the subject WITHOUT\n' >&2
    printf '  executing it (a lint, a hash), use --no-load-witness and read the caveat.\n' >&2
    exit 3
fi
if [ -n "$PREDICT" ]; then
    mg_predict_validate || exit 3
fi

# ---------------------------------------------------------------------------
# APPLY. Suite mode: to a COPY beside the original, so the tracked file is
# never edited. Beside it, not in $TMPDIR: a suite resolves its fixtures from
# `dirname "${BASH_SOURCE[0]}"`, and moving it would change what is under test.
# The name begins with a dot so no `test-*.sh` glob can pick it up.
# Subject mode: to the subject inside the SECOND tree copy, at the line the
# witness pushed it to; the suite that runs is that tree's own.
# ---------------------------------------------------------------------------
if [ -n "$SUBJECT_ABS" ]; then
    PRISTINE="$T0/$SUBJ_REL"; MUTFILE="$T1/$SUBJ_REL"; MUT_SCRIPT="$T1/$SUITE_REL"
else
    MUT="$SUITE_DIR/.mutgate-$$-$(basename "$SUITE_ABS")"
    # Removed by mg_cleanup (installed beside the workdir allocation above).
    PRISTINE="$SUITE_ABS"; MUTFILE="$MUT"; MUT_SCRIPT="$MUT"
fi
MLINE=$(( LINE + WITNESS_OFF ))
# The line about to be mutated must be the line that was judged eligible — the
# witness offset is arithmetic, and arithmetic about line numbers is how a
# mutant lands one row off and reports on its neighbour (#1163).
if [ "$(sed -n "${MLINE}p" "$PRISTINE")" != "$(sed -n "${LINE}p" "$TARGET_ABS")" ]; then
    printf 'mutation-gate.sh: REFUSED — line %s of the copy is not line %s of the target. Nothing was tested.\n' "$MLINE" "$LINE" >&2
    exit 3
fi

case "$MODE" in
  subst)     SUBST_NEW="$SUBST_NEW" awk -v L="$MLINE" 'NR==L{ print ENVIRON["SUBST_NEW"]; next } { print }' "$PRISTINE" > "$WORKDIR/mutfile" ;;
  delete)    awk -v L="$MLINE" 'NR==L{ printf "# %s\n", $0; next } { print }' "$PRISTINE" > "$WORKDIR/mutfile" ;;
  duplicate) awk -v L="$MLINE" 'NR==L{ print; print; next } { print }'        "$PRISTINE" > "$WORKDIR/mutfile" ;;
  if-true|if-false)
             awk -v L="$MLINE" -v V="${MODE#if-}" '
                 NR==L { match($0, /^[ \t]*/); ind = substr($0, 1, RLENGTH)
                         kw = ($0 ~ /^[ \t]*elif[ \t]/) ? "elif" : "if"
                         print ind kw " " V "; then"; next }
                 { print }' "$PRISTINE" > "$WORKDIR/mutfile" ;;
esac
if [ -n "$SUBJECT_ABS" ]; then
    cat "$WORKDIR/mutfile" > "$MUTFILE"           # cat, not mv: keep the mode bits
else
    cat "$WORKDIR/mutfile" > "$MUTFILE"
    chmod --reference="$SUITE_ABS" "$MUT" 2>/dev/null || chmod +x "$MUT"
fi

# PROVE THE MUTATION APPLIED (#938). An INERT mutant and a genuinely surviving
# one produce byte-identical output — green suite, "SURVIVED" — so a sweep that
# does not check this can report a coverage hole that does not exist, or miss
# one that does.
if cmp -s "$PRISTINE" "$MUTFILE"; then
    printf 'mutation-gate.sh: REFUSED — the mutation did not change the file. Nothing was tested.\n' >&2
    exit 3
fi
changed=$(diff <(cat "$PRISTINE") <(cat "$MUTFILE") | grep -c '^[<>]')
mut_line=$(sed -n "${MLINE}p" "$MUTFILE")
case "$MODE" in
  delete)
    case "$mut_line" in
      '#'*) : ;;
      *) printf 'mutation-gate.sh: REFUSED — line %s of the mutant is not a comment: %s\n' "$MLINE" "$mut_line" >&2; exit 3 ;;
    esac
    [ "$changed" -eq 2 ] || { printf 'mutation-gate.sh: REFUSED — expected exactly one changed line, diff shows %s\n' "$changed" >&2; exit 3; } ;;
  duplicate)
    [ "$changed" -eq 1 ] || { printf 'mutation-gate.sh: REFUSED — expected exactly one added line, diff shows %s\n' "$changed" >&2; exit 3; } ;;
  subst)
    [ "$mut_line" = "$SUBST_NEW" ] || { printf 'mutation-gate.sh: REFUSED — line %s of the mutant is not the rewritten line: %s\n' "$MLINE" "$mut_line" >&2; exit 3; }
    [ "$changed" -eq 2 ] || { printf 'mutation-gate.sh: REFUSED — expected exactly one changed line, diff shows %s\n' "$changed" >&2; exit 3; } ;;
  if-true|if-false)
    if ! grep -qE "^[[:space:]]*(if|elif) ${MODE#if-}; then\$" <<<"$mut_line"; then
        printf 'mutation-gate.sh: REFUSED — line %s of the mutant is not the forced condition: %s\n' "$MLINE" "$mut_line" >&2; exit 3
    fi
    [ "$changed" -eq 2 ] || { printf 'mutation-gate.sh: REFUSED — expected exactly one changed line, diff shows %s\n' "$changed" >&2; exit 3; } ;;
esac
printf '  mutation applied and verified at line %s of %s (mode=%s)\n' "$LINE" "${SUBJ_REL:-the suite}" "$MODE"
# REPORT THE DIFF, NOT A HASH (section 4): this is the edit a reproducer needs.
diff <(cat "$PRISTINE") <(cat "$MUTFILE") | grep '^[<>]' | sed 's/^/    /'

# A mutant that does not PARSE is a kill for a reason having nothing to do with
# the assertion. Caught here so it is reported as such rather than counted.
if ! bash -n "$MUTFILE" 2>"$WORKDIR/parse.err"; then
    printf 'VERDICT: killed-unattributable (the mutant does not parse)\n'
    printf '  %s\n' "$(head -2 "$WORKDIR/parse.err" | tr '\n' ' ')"
    printf '  A syntax kill says nothing about the assertion. Not evidence.\n'
    exit 5
fi

echo "=== mutant ==="
: > "$WORKDIR/witness"
mut_rc=$(mg_run "$MUT_SCRIPT" "$WORKDIR/mutant")
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

mg_flipset "$WORKDIR/baseline.out" "$WORKDIR/mutant.out" "$WORKDIR/mutant.err"

if [ "$mut_rc" -eq 0 ]; then
    if [ -n "$SUBJECT_ABS" ] && [ "$LOAD_WITNESS" = 0 ]; then
        printf 'VERDICT: survived-unwitnessed\n'
        printf '  The suite stayed green, and with --no-load-witness this tool cannot tell a\n'
        printf '  suite that does not catch the defect from a suite that never READ the\n'
        printf '  mutated file. NOT evidence of a coverage gap, and not evidence against one.\n'
        mg_finish 5 survived-unwitnessed
    fi
    if [ -n "$SUBJECT_ABS" ] && [ ! -s "$WORKDIR/witness" ]; then
        printf 'mutation-gate.sh: REFUSED — the MUTANT arm never executed the subject copy, though the baseline did.\n' >&2
        printf '  The two arms took different paths to the subject; a green here is not a survivor.\n' >&2
        exit 3
    fi
    printf 'VERDICT: survived\n'
    if [ -n "$SUBJECT_ABS" ]; then
        printf '  The mutation was PROVEN applied (diff above), the suite PROVABLY executed the\n'
        printf '  mutated subject (load witness), and it still passed — so this suite would NOT\n'
        printf '  catch this defect at %s:%s. Either nothing reaches the line, or what reaches\n' "$SUBJ_REL" "$LINE"
        printf '  it is defended by a DIFFERENT guard (the #1519 shape). Both are coverage gaps.\n'
    else
        printf '  The mutation was PROVEN applied (diff checked above) and the suite still\n'
        printf '  passed — so nothing in it asserts what line %s asserts.\n' "$LINE"
    fi
    mg_finish 4 survived
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
    mg_print_flipset
    mg_finish 0 killed-by-assertion
fi
printf 'VERDICT: killed-unattributable (rc %s, no witness)\n' "$mut_rc"
printf '  The suite reddened and the harness cannot name WHICH assertion did it.\n'
printf '  #1032 round 2 produced exactly this: a red whose assertion total was\n'
printf '  16 before and 16 after, i.e. the count guard was never reached.\n'
mg_print_flipset
mg_finish 5 killed-unattributable
