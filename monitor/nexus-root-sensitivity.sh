#!/usr/bin/env bash
# nexus-root-sensitivity — detect test suites that leak the INHERITED
# $NEXUS_ROOT (your-org/nexus-code#655, #706, #708).
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS, AND WHY IT IS NOT ANOTHER PASS/FAIL DIFF
# ---------------------------------------------------------------------------
#
# monitor/spawn-worker.sh honours an INHERITED NEXUS_ROOT over its own
# script-relative root (#577), and exports NEXUS_ROOT into every worker. So a
# suite that builds a FIXTURE nexus and spawns against it is, inside an agent
# shell, silently spawning against the OPERATOR'S PRIMARY TREE instead.
#
# Four members of this class are known. The existing detectors are both
# OUTPUT-BASED — they compare exit status / assertion tallies between an
# `NEXUS_ROOT`-unset and an `NEXUS_ROOT`-exported run:
#
#   * .github/workflows/tests.yml, job `inherited-root` — the whole band under
#     an exported root, every push.
#   * a human running the band twice and diffing (how #706 and #708 were found).
#
# Both are structurally blind to the class's dominant form. Measured on
# test-worker-nproc-bound.sh with its scrub removed (#655 round 12, reproduced
# by its skeptic): the re-root FIRES, three spawn rows and three
# windows/*.json provenance records are written into the inherited tree, and
# *every assertion still passes* — byte-identical output, rc=0. A PASS/FAIL
# diff cannot see that, by construction. The suite is SENSITIVE BUT GREEN.
#
# The contamination is nonetheless real, and it is an ARTIFACT rather than an
# opinion: as of 2026-08-05 the operator's primary action log holds 616 spawn
# rows whose `workdir` is under /tmp/ — 23% of every spawn event it has ever
# recorded — all carrying `rerooted-from`, across 41 fixture window names.
#
# So this tool measures the SIDE EFFECT, not the verdict:
#
#   probe   — PRESENT TENSE. Run a suite with NEXUS_ROOT exported to a fresh
#             decoy nexus root, then diff the decoy tree. Any byte written
#             into it is a leak, whatever the suite's exit status.
#   audit   — RETROSPECTIVE. Enumerate members from fixture spawn rows already
#             in an action log, then re-probe each implicated suite so the
#             report distinguishes "still leaks" from "leaked once, fixed".
#
# ---------------------------------------------------------------------------
# WHY THE PROPERTY IS TESTED BEHAVIOURALLY AND NOT BY GREPPING FOR A SPELLING
# ---------------------------------------------------------------------------
#
# The property is "this suite controls NEXUS_ROOT for its spawns". It has at
# least three spellings in this repo — `unset NEXUS_ROOT`, `env -u NEXUS_ROOT`,
# and pinning `NEXUS_ROOT=<fixture>` at every spawn call site — and #655's own
# round 12 enumerated the class with `grep 'unset NEXUS_ROOT'`, a SPELLING test
# standing in for the PROPERTY test. It inflated the candidate set 2.3x (28
# reported, 12 real) and produced a published false positive, because 16 suites
# satisfy the property by pinning instead of scrubbing.
#
# A lint that greps three spellings instead of one is the same defect with a
# longer list; the fourth spelling still walks past it. `probe` asserts the
# property itself, so any spelling that achieves it passes and any that does
# not fails. `spellings` reproduces the static view for COMPARISON ONLY — it is
# a diagnostic, never the gate.
#
# ---------------------------------------------------------------------------
# WHAT THIS DOES NOT CATCH — stated, not glossed
# ---------------------------------------------------------------------------
#
# This is a WRITE detector. A suite that only READS the inherited root leaks
# nothing into the decoy and is reported hermetic. test-erofs-escalation.sh
# (#708) is exactly that shape: it PATH-shadows `sandbox-notify` and
# locals-env.sh fronts $NEXUS_ROOT/monitor/notifywrap ahead of the stub. That
# member is caught by the OUTPUT-based `inherited-root` CI job, because the
# read changed its assertions.
#
# The two instruments are complements, and the honest coverage statement is:
#
#   leak changes assertions   -> caught by `inherited-root` (output-based)
#   leak writes to the root   -> caught by `probe` (this tool)
#   leak only READS, silently -> caught by NEITHER. Residual blind spot.
#
# Run both. Neither alone is a census.
#
# Usage:
#   monitor/nexus-root-sensitivity.sh probe <suite.sh>...
#   monitor/nexus-root-sensitivity.sh band [--timeout N] [suite.sh...]
#   monitor/nexus-root-sensitivity.sh audit [--log PATH] [--no-verify]
#   monitor/nexus-root-sensitivity.sh spellings [suite.sh...]
#   monitor/nexus-root-sensitivity.sh self-test
#
# Exit: 0 = no leak among suites that produced evidence
#       1 = at least one suite leaked
#       2 = usage / environment error
#       3 = incomplete: a suite timed out or declined to run, so the run is
#           NOT a clean bill of health (never reported as 0).

set -uo pipefail

PROG=${0##*/}
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TIMEOUT_SECS=${NRS_TIMEOUT:-420}
MAX_LEAK_LINES=${NRS_MAX_LEAK_LINES:-25}
KEEP_DECOY=0
VERIFY=1
AUDIT_LOG=""

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
say() { printf '%s\n' "$*"; }

loadavg() { cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo 'n/a'; }

# ---------------------------------------------------------------------------
# Decoy construction.
#
# The decoy is the WHOLE TRACKED WORKING TREE, mirroring the CI job's
# "$GITHUB_WORKSPACE is a sufficient decoy root" reasoning. It is not a
# convenience choice — it is the difference between a measurement and a false
# negative, and this tool's own first self-test proved it:
#
#   A decoy of monitor/ + config/ ALONE satisfies spawn-worker.sh's
#   `_sw_root_is_nexus` predicate (`-x $root/monitor/spawn-worker.sh` and
#   `-d $root/config`, spawn-worker.sh:598) and the re-root FIRES — but the
#   spawn then dies at `spawn-worker: floor file missing:
#   $decoy/skills/nexus.worker-defaults/SKILL.md` with rc=2, BEFORE writing any
#   state. Nothing leaks, and the known positive comes back `hermetic`.
#
# So `_sw_root_is_nexus` is NECESSARY BUT NOT SUFFICIENT for a decoy. A thin
# decoy does not merely under-report; it reports the exact opposite of the
# truth, silently, on the one suite we already know is a member. `probe_vacuity_guard`
# below is the backstop for the general case, since the next required path is
# not something this file can enumerate ahead of time either.
#
# Tracked files only: node_modules/ and locals/ are gitignored and absent from
# a GitHub checkout too, so their absence here is faithful rather than a gap.
# ---------------------------------------------------------------------------
make_decoy() {
    local dest="$1"
    mkdir -p "$dest" || return 1

    local list; list=$(mktemp "${TMPDIR:-/tmp}/nrs-files-XXXXXX")
    if git -C "$REPO_ROOT" ls-files -z > "$list" 2>/dev/null && [ -s "$list" ]; then
        tar -C "$REPO_ROOT" --null -T "$list" --ignore-failed-read -cf - 2>/dev/null \
            | tar -xf - -C "$dest" 2>/dev/null
    else
        # Not a git checkout — fall back to the two directories that at least
        # satisfy the predicate, and let the vacuity guard catch the shortfall.
        cp -a "$REPO_ROOT/monitor" "$dest/" 2>/dev/null
        cp -a "$REPO_ROOT/config"  "$dest/" 2>/dev/null
    fi
    rm -f "$list"

    # A decoy carrying the source tree's own .state would make the baseline
    # snapshot noisy and could mask a leak inside an already-large file. So the
    # CONTENTS go — but the DIRECTORY is recreated EMPTY, and that is not a
    # detail (your-org/nexus-code#833).
    #
    # Deleting the directory outright made this probe structurally blind to
    # every leak that only writes into a directory that ALREADY EXISTS, and the
    # operator's live tree always has one. `ng`'s usage tap is exactly that
    # shape: `[[ -n "$verb" && -d "$STATE_DIR" ]] || return 0` — it never
    # creates its state dir, it only appends when one is there. Measured, same
    # suite, same exported root, the only difference being this directory:
    #
    #   root without monitor/.state -> no write at all      -> "hermetic"
    #   root with    monitor/.state -> 13 rows appended      -> LEAK
    #
    # So `test-ng-report-check.sh` and `test-ng-reply-repo.sh` were reported
    # hermetic by this tool while demonstrably writing into the inherited root
    # on a CI runner (#720's attribution). The verdict was not wrong about what
    # it looked at; the decoy was missing the condition the class needs.
    rm -rf "$dest/monitor/.state"
    mkdir -p "$dest/monitor/.state"

    [ -d "$dest" ] && [ -x "$dest/monitor/spawn-worker.sh" ] && [ -d "$dest/config" ] || {
        printf '%s: decoy at %s does NOT satisfy _sw_root_is_nexus — probe would be vacuous\n' \
               "$PROG" "$dest" >&2
        return 1
    }
    return 0
}

# Did the run prove anything? A suite whose spawns died because the DECOY was
# missing a file cannot leak, and reporting that as `hermetic` is a false
# negative dressed as a clean bill of health — the precise failure this tool
# exists to retire, one level up. Any complaint naming the decoy path alongside
# a missing/not-found signal means the probe was vacuous, and it says so.
probe_vacuity_guard() {
    local out="$1" decoy="$2"
    # `<<<` rather than a pipe into `grep -q`: a -q grep exits at its first
    # match and SIGPIPEs the upstream reader, which is a red under
    # test-sigpipe-assertion-lint.sh.
    grep -qiE 'missing|not found|no such file|cannot (open|read|find)|unreadable' \
        <<<"$(grep -F -- "$decoy" "$out" 2>/dev/null)"
}

# Snapshot every path under the decoy: type, relative path, and for regular
# files a content hash. Content-hashing rather than mtime/size alone because a
# same-size in-place rewrite within one second is a real leak shape and stat
# granularity would miss it.
snapshot() {
    local root="$1" out="$2"
    {
        find "$root" -mindepth 1 -type f -print0 2>/dev/null \
            | sort -z \
            | xargs -0 -r md5sum 2>/dev/null \
            | sed "s|$root/||"
        find "$root" -mindepth 1 \( -type d -o -type l \) -printf 'DIR-OR-LINK %P\n' 2>/dev/null \
            | sort
    } > "$out" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# probe_one <suite-path>
#
# Prints one TSV record on stdout:
#   <suite>\t<verdict>\t<rc>\t<tally>\t<leaked-paths-count>\t<loadavg>
# and a human block on fd 3 (collected by the caller).
#
# verdict: LEAK | ALLOWED | hermetic | SKIP | TIMEOUT | VACUOUS
# ---------------------------------------------------------------------------
probe_one() {
    local suite="$1"
    local rel="${suite#"$REPO_ROOT"/}"
    local work decoy before after rc out tally verdict leaked_n la_before
    local marker_reason=""

    work=$(mktemp -d "${TMPDIR:-/tmp}/nrs-XXXXXX") || { echo "mktemp failed" >&2; return 2; }
    decoy="$work/decoy"
    before="$work/before.txt"; after="$work/after.txt"; out="$work/out.txt"

    if ! make_decoy "$decoy"; then
        rm -rf "$work"; return 2
    fi
    snapshot "$decoy" "$before"

    # Tripwire: no record referencing THIS DECOY may appear in the REAL state
    # directory. Contaminating the operator's canonical state is exactly the
    # harm this tool measures, so it is worth a check — but the check must be
    # attributable, and its coverage must be stated (see AXIS below).
    #
    # It used to compare the action log's LINE COUNT before and after, and that
    # is unsound on a live primary: the orchestrator writes to that log
    # continuously, so a multi-minute probe races it. It fired on the first
    # real run and the growth was two unrelated `paste-followup` rows for
    # another window — a false positive of exactly the "silence/noise used as
    # a proxy" shape this chain keeps paying for. Match on the decoy path
    # instead; that cannot be produced by anyone but this probe.

    la_before=$(loadavg)

    # env -i is deliberately NOT used: the point is to reproduce the AGENT's
    # environment, which is where this class bites.
    #
    # NEXUS_LOCALS moves WITH NEXUS_ROOT. Leaving it pointing at the operator's
    # real locals/ defeats the isolation in a way that reads as a clean result:
    # bash_env.sh fronts $NEXUS_LOCALS/bin, so a bare `ng` in a suite resolves
    # to the PRIMARY's wrapper and writes to the PRIMARY's state — off the
    # decoy entirely, so the probe sees nothing and reports `hermetic`. The
    # canonical drive (`env -u NEXUS_ROOT -u NEXUS_LOCALS`) and CI's clean-env
    # job both treat the two as one axis, and so must this.
    timeout -k 10 "$TIMEOUT_SECS" \
        env NEXUS_ROOT="$decoy" NEXUS_LOCALS="$decoy/locals" \
            bash "$suite" >"$out" 2>&1
    rc=$?

    snapshot "$decoy" "$after"

    # AXIS, stated because a tripwire's silence is worth exactly what its
    # coverage is: this scans EVERY file under the real .state directory (not
    # just action-log.jsonl, which was the first version's blind spot), and it
    # matches on the DECOY PATH. So it sees any write that RECORDS a path, and
    # it is blind to a write that records none — `notify-decisions.jsonl` and
    # `ng-usage.jsonl` rows carry a window and a message, not a root, so a leak
    # into those files would not trip this. Do not quote its silence as "the
    # primary was not written to"; quote it as "no path-bearing row named this
    # decoy". The real containment is NEXUS_ROOT/NEXUS_LOCALS both pointing at
    # the decoy; this is defence in depth with a known edge.
    local real_state="${NEXUS_ROOT:-}/monitor/.state"
    if [ -d "$real_state" ] \
       && grep -rqlF -- "$decoy" "$real_state" 2>/dev/null; then
        printf '%s: FATAL — a record naming this decoy reached the REAL state dir %s\n' \
               "$PROG" "$real_state" >&2
        printf '%s: during the probe of %s. The decoy did not contain the write.\n' "$PROG" "$rel" >&2
        grep -rlF -- "$decoy" "$real_state" 2>/dev/null | head -5 | sed 's/^/    /' >&2
        # `exit` here would only leave the command substitution this function
        # runs inside — the caller would sail on. Drop a sentinel the caller
        # checks instead. (Observed: an `exit 2` here was swallowed and the
        # band continued to completion.)
        : > "${NRS_ABORT_SENTINEL:-/dev/null}"
        rm -rf "$work"
        return 2
    fi

    local leakfile="$work/leak.txt"
    diff "$before" "$after" 2>/dev/null | grep -E '^[<>]' > "$leakfile"
    leaked_n=$(grep -c . "$leakfile" ; true)
    leaked_n=${leaked_n%%[!0-9]*}
    : "${leaked_n:=0}"

    tally=$(grep -oE '=== summary: [0-9]+ passed, [0-9]+ failed ===' "$out" | tail -1)
    [ -n "$tally" ] || tally=$(grep -oE '[0-9]+ passed, [0-9]+ failed' "$out" | tail -1)
    [ -n "$tally" ] || tally='(no tally)'

    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        verdict=TIMEOUT
    elif [ "$rc" -eq 77 ]; then
        verdict=SKIP            # declined to run: NO EVIDENCE, not a clean bill
    elif [ "$leaked_n" -gt 0 ]; then
        # THE THIRD DISJUNCT of round 12's `scrub OR pin OR explicit marker`,
        # wired into the GATE rather than only into the `spellings` diagnostic.
        # It was advertised in the remediation text for four commits while
        # nothing read it — a remediation instruction that does not work is
        # worse than none, because the author follows it and the gate still
        # reddens.
        #
        # The reason is REQUIRED. A bare marker is an unexplained exemption,
        # and the whole point of an opt-out is that someone wrote down why; a
        # marker with nothing after it is reported as invalid and still LEAKs.
        verdict=LEAK
        local mk
        mk=$(grep -m1 -F 'nexus-root-sensitivity: allow-inherited-root' "$suite" 2>/dev/null)
        if [ -n "$mk" ]; then
            local reason
            reason=$(sed 's/.*nexus-root-sensitivity: allow-inherited-root//' <<<"$mk" \
                     | sed 's/^[[:space:]:—-]*//; s/[[:space:]]*$//')
            if [ -n "$reason" ]; then
                verdict=ALLOWED
                marker_reason="$reason"
            else
                marker_reason="INVALID: marker present but carries no reason"
            fi
        fi
    elif probe_vacuity_guard "$out" "$decoy"; then
        # No leak, but the run complained that the DECOY was incomplete — so
        # "no leak" is not a finding. Never silently downgraded to hermetic.
        verdict=VACUOUS
    else
        verdict=hermetic
    fi

    {
        printf '\n--- %s\n' "$rel"
        printf '    verdict=%s rc=%s tally=[%s] loadavg=[%s] leaked-paths=%s\n' \
               "$verdict" "$rc" "$tally" "$la_before" "$leaked_n"
        if [ "$verdict" = LEAK ] || [ "$verdict" = ALLOWED ]; then
            # The combination that matters: GREEN and LEAKING is invisible to
            # every output-based detector in this repo.
            if [ "$rc" -eq 0 ] && [ "$verdict" = LEAK ]; then
                printf '    *** SENSITIVE BUT GREEN — rc=0 while writing into the inherited root.\n'
                printf '    *** No PASS/FAIL diff, local or in CI, can see this.\n'
            fi
            if [ "$verdict" = ALLOWED ]; then
                printf '    ALLOWED by an explicit marker — reason: %s\n' "$marker_reason"
                printf '    (still reported: an exemption is not an absence.)\n'
            elif [ -n "$marker_reason" ]; then
                printf '    marker REJECTED — %s\n' "$marker_reason"
            fi
            printf '    paths written into the decoy (first %s):\n' "$MAX_LEAK_LINES"
            sed "s|^|      |" "$leakfile" | head -n "$MAX_LEAK_LINES"
        fi
        if [ "$verdict" = SKIP ]; then
            printf '    suite declined to run (exit 77) — NO EVIDENCE. Not a pass.\n'
        fi
        if [ "$verdict" = VACUOUS ]; then
            printf '    *** VACUOUS — nothing leaked, but the run reported the DECOY\n'
            printf '    *** itself was incomplete, so the spawn died before it could\n'
            printf '    *** write. This proves nothing. Complaints naming the decoy:\n'
            grep -F -- "$decoy" "$out" 2>/dev/null \
                | grep -iE 'missing|not found|no such file|cannot (open|read|find)|unreadable' \
                | head -5 | sed 's|^|      |'
        fi
    } >&3

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$verdict" "$rc" "$tally" "$leaked_n" "$la_before"

    if [ "$KEEP_DECOY" = 1 ]; then
        printf '%s: decoy retained at %s\n' "$PROG" "$work" >&2
    else
        rm -rf "$work"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Suite population: files that build a FIXTURE nexus, i.e. that create a temp
# tree and copy a real monitor/ script into it. This is a DISCOVERY heuristic
# for the default band selection only — it never decides the verdict, and
# `probe` accepts explicit paths so a suite the heuristic misses can still be
# measured. Stated because #655's round 12 published a heuristic population as
# if it were a census.
# ---------------------------------------------------------------------------
# THE POPULATION IS DERIVED FROM THE CLASS, NOT INHERITED FROM ONE INSTANCE OF
# IT (your-org/nexus-code#833).
#
# The original predicate was "builds a temp root AND references
# spawn-worker/launcher/bootstrap-recover", which is exactly right for `#655`'s
# SPAWNING class: those three scripts are the ones that honour an inherited
# NEXUS_ROOT when they spawn. `#833` is a DIFFERENT class through the same
# variable — a fixture that runs `ng`, whose `_resolve_state_dir` prefers the
# inherited root — and such a fixture need not mention any of those three.
#
# So fixing the decoy (which made the probe able to SEE the class) did not make
# the gate LOOK at the suites that exhibit it: `watcher/test-ng-reply-repo.sh`
# and `watcher/test-ng-report-check.sh` are measured leakers and neither was in
# the population. Blindness moved from "cannot see" to "does not look", which is
# the same defect one level out and reads identically from the summary.
#
# The union, one arm per class, each naming the consumer that honours the
# inherited root:
#
#   SPAWN  spawn-worker.sh | launcher.sh | bootstrap-recover.sh
#   NG     a fixture `ng` — the binary is COPIED or INVOKED from a temp tree
#
# The `ng` arm is deliberately broad: any suite that puts `ng` in a fixture is a
# candidate, because the resolution order is a property of `ng`, not of what the
# suite does with it. Over-inclusion costs a probe; under-inclusion is how a
# known offender sits outside the gate.
#
# VERIFIED BY THE ONLY TEST THAT MATTERS: all three measured leakers are in this
# population — asserted by `test-nrs-population.sh`, which names them, so a
# future narrowing of this predicate reddens instead of silently shrinking the
# gate.
fixture_suites() {
    local f
    for f in "$REPO_ROOT"/monitor/test-*.sh "$REPO_ROOT"/monitor/watcher/test-*.sh; do
        [ -f "$f" ] || continue
        # Every member builds a throwaway root; that is common to both classes.
        grep -qE 'mktemp -d|TMPDIR' "$f" 2>/dev/null || continue
        # SPAWN class (#655): honours the inherited root when it spawns.
        if grep -qE 'spawn-worker\.sh|launcher\.sh|bootstrap-recover\.sh' "$f" 2>/dev/null; then
            printf '%s\n' "$f"; continue
        fi
        # NG class (#833): a fixture `ng`, copied into or invoked from the temp
        # tree. `_resolve_state_dir` prefers the inherited NEXUS_ROOT over the
        # fixture, so the copy is not a sandbox.
        if grep -qE 'cp .*/ng"?( |$)|/monitor/ng"|NG="\$[A-Za-z_]*/monitor/ng"|setup_fake_nexus' "$f" 2>/dev/null; then
            printf '%s\n' "$f"; continue
        fi
    done
}

# ---------------------------------------------------------------------------
# The STATIC spelling view — a diagnostic for comparison with `band`, NEVER a
# gate. Reports which of the three known spellings each suite uses.
# ---------------------------------------------------------------------------
cmd_spellings() {
    local -a suites
    if [ "$#" -gt 0 ]; then suites=("$@"); else mapfile -t suites < <(fixture_suites); fi
    say "# static spelling view — DIAGNOSTIC ONLY, not the gate."
    say "# suite<TAB>scrub<TAB>pin<TAB>marker"
    local f scrub pin marker
    for f in "${suites[@]}"; do
        scrub=no; pin=no; marker=no
        grep -qE '^[[:space:]]*(unset[[:space:]]+NEXUS_ROOT|env -u NEXUS_ROOT)' "$f" && scrub=yes
        grep -qE 'env -u NEXUS_ROOT' "$f" && scrub=yes
        grep -qE 'NEXUS_ROOT=(\"?\$)' "$f" && pin=yes
        grep -qF 'nexus-root-sensitivity: allow-inherited-root' "$f" && marker=yes
        printf '%s\t%s\t%s\t%s\n' "${f#"$REPO_ROOT"/}" "$scrub" "$pin" "$marker"
    done
}

# ---------------------------------------------------------------------------
# audit — retrospective enumeration from an action log.
# ---------------------------------------------------------------------------

# Map a fixture window name to the suite that produces it.
#   stage 1: literal match of the whole name
#   stage 2: strip a trailing -<digits> (a $$ / PID suffix) and match the stem
#            as a prefix literal. `cwd-leak-test-2250` evaded #655 round 12's
#            first pass for exactly this reason, so the fallback is not
#            optional.
# A name that matches NOTHING is reported as UNMAPPED. It is never dropped:
# a silently discarded row is an under-count of the class, which is the error
# mode this whole file is about.

# Files matching `needle` in a line that is not itself an action-log RECORD.
# A file that embeds a log fixture (this tool's own test suite does) contains
# every window name it tests, and a naive grep attributes those windows to it —
# which then gets probed, comes back hermetic, and is reported as a
# "historical member" that was never a member at all. A line recording a spawn
# is evidence ABOUT a window, never a producer OF one, so it is excluded.
_grep_producers() {
    local needle="$1" f out=""
    # NRS_SUITE_ROOT exists so this exclusion is TESTABLE. Pointed at the real
    # tree it is unfalsifiable from inside the repo: the only way to exercise
    # "a file that merely records a window is not its producer" is to have such
    # a file in the search set, and planting one under monitor/watcher/test-*.sh
    # would put it in CI's discovery glob. A mutant proved the point — with the
    # exclusion deleted the suite stayed green, because the fixture had been
    # made non-self-referential and the assertion was passing for the wrong
    # reason.
    local root="${NRS_SUITE_ROOT:-$REPO_ROOT}"
    for f in "$root"/monitor/test-*.sh "$root"/monitor/watcher/test-*.sh; do
        [ -f "$f" ] || continue
        # `<<<`, not a pipe into `grep -q` — see probe_vacuity_guard.
        if grep -qv '"event"[[:space:]]*:[[:space:]]*"spawn"' \
              <<<"$(grep -F -- "$needle" "$f" 2>/dev/null)" \
           && grep -qF -- "$needle" "$f" 2>/dev/null; then
            out+="$f"$'\n'
        fi
    done
    printf '%s' "$out"
}

map_window_to_suite() {
    local win="$1" hits stem
    hits=$(_grep_producers "$win")
    if [ -z "$hits" ]; then
        stem="${win%-*}"
        if [ "$stem" != "$win" ] && [ -n "$stem" ]; then
            hits=$(_grep_producers "$stem-")
        fi
    fi
    if [ -z "$hits" ]; then printf 'UNMAPPED\n'; return 0; fi
    printf '%s\n' "$hits" | grep -v '^$' | sed "s|${NRS_SUITE_ROOT:-$REPO_ROOT}/||" | sort -u | paste -sd,
}

cmd_audit() {
    local log="${AUDIT_LOG:-${NEXUS_ROOT:-}/monitor/.state/action-log.jsonl}"
    [ -f "$log" ] || die "no action log at $log (pass --log PATH)"
    command -v jq >/dev/null || die "jq required"

    say "# nexus-root-sensitivity: RETROSPECTIVE audit"
    say "# log: $log"
    say ""

    local total fixture
    total=$(jq -c 'select(.event=="spawn")' "$log" | wc -l)
    fixture=$(jq -c 'select(.event=="spawn") | select(.workdir != null and (.workdir|startswith("/tmp/"))) | select(has("rerooted-from"))' "$log" | wc -l)
    say "spawn rows total                         : $total"
    say "  ... with a /tmp/ workdir + rerooted-from: $fixture"
    if [ "$fixture" -eq 0 ]; then
        say ""
        say "No fixture spawn rows. NOTE: this is a RETROSPECTIVE instrument —"
        say "a sensitive suite that has never been RUN with NEXUS_ROOT exported"
        say "leaves no row. Zero here is not a clearance; run \`band\` for the"
        say "present-tense property test."
        return 0
    fi

    local -a wins
    mapfile -t wins < <(jq -r 'select(.event=="spawn") | select(.workdir != null and (.workdir|startswith("/tmp/"))) | select(has("rerooted-from")) | .window' "$log" | sort -u)
    say "  ... distinct fixture window names       : ${#wins[@]}"
    say "  ... window                              : $(jq -r 'select(.event=="spawn") | select(.workdir != null and (.workdir|startswith("/tmp/"))) | .ts' "$log" | sort | sed -n '1p' ) -> $(jq -r 'select(.event=="spawn") | select(.workdir != null and (.workdir|startswith("/tmp/"))) | .ts' "$log" | sort | tail -1)"
    say ""

    local w s
    local -a implicated=()
    say "window -> suite"
    for w in "${wins[@]}"; do
        s=$(map_window_to_suite "$w")
        printf '  %-26s %s\n' "$w" "$s"
        [ "$s" = UNMAPPED ] || implicated+=("$s")
    done

    local -a uniq_suites=()
    mapfile -t uniq_suites < <(printf '%s\n' "${implicated[@]}" | tr ',' '\n' | sort -u | grep -v '^$')
    say ""
    say "implicated suites: ${#uniq_suites[@]}"

    if [ "$VERIFY" = 0 ]; then
        printf '%s\n' "${uniq_suites[@]}"
        say ""
        say "(--no-verify: NOT classified. A detector hit means this suite"
        say " contaminated canonical state AT SOME POINT — never that it is"
        say " broken NOW. Re-run without --no-verify to classify.)"
        return 0
    fi

    # ---------------------------------------------------------------------
    # The MANDATORY cross-check. #655 round 12 published a fifth member off a
    # detector hit alone and had to retract it: the suite had been FIXED six
    # days earlier. Detector-positive is a statement about the PAST.
    #
    # And the classification is BEHAVIOURAL, not `git log -S`. Round 12 dated
    # that fix by `git log -S` and concluded the pin "predates the rows by
    # hours"; the commit is 2026-07-30T13:20:16 and the rows span 12:53 ->
    # 13:28, so 22 rows precede it and 2 follow it. The dating was wrong and
    # the conclusion survived only because a live re-run happened to agree.
    # Re-running the suite is the evidence; git archaeology is a footnote.
    # ---------------------------------------------------------------------
    say ""
    say "re-probing each implicated suite (present tense) ..."
    local rec verdict any_current=0 incomplete=0
    exec 3>&1
    for s in "${uniq_suites[@]}"; do
        # SOURCE GONE is an UNMEASURED suite, not a benign note. It used to
        # `continue` without touching `incomplete`, so an audit whose every
        # implicated suite had been renamed exited 0 — "no current members"
        # from zero classifications.
        [ -f "$REPO_ROOT/$s" ] || {
            printf '  %-52s UNKNOWN (source gone — renamed or deleted)\n' "$s"
            incomplete=1
            continue
        }
        rec=$(probe_one "$REPO_ROOT/$s" 3>/dev/null)
        verdict=$(printf '%s' "$rec" | cut -f2)
        case "$verdict" in
            LEAK)     printf '  %-52s MEMBER (still leaks)\n' "$s"; any_current=1 ;;
            # NOT "historical member": window->suite is a text heuristic and can
            # over-include (a suite that merely mentions the name). Hermetic
            # means "does not leak today" — which covers both a member that was
            # fixed and a file that was never a producer at all. Distinguishing
            # those needs the suite's history, not this run, so it is not
            # claimed here.
            hermetic) printf '  %-52s hermetic now (fixed, or never a producer)\n' "$s" ;;
            SKIP)     printf '  %-52s UNKNOWN (declined to run — no evidence)\n' "$s"; incomplete=1 ;;
            TIMEOUT)  printf '  %-52s UNKNOWN (timed out at %ss)\n' "$s" "$TIMEOUT_SECS"; incomplete=1 ;;
            *)        printf '  %-52s UNKNOWN (%s)\n' "$s" "$verdict"; incomplete=1 ;;
        esac
    done
    exec 3>&-

    say ""
    say "BOUNDARY: retrospective only. A sensitive suite never run under an"
    say "exported NEXUS_ROOT leaves no row here — this is a LOWER BOUND, with a"
    say "blind spot disjoint from the output-based detectors'."
    [ "$incomplete" = 1 ] && return 3
    [ "$any_current" = 1 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
# band / probe
# ---------------------------------------------------------------------------
run_probes() {
    local -a suites=("$@")
    local rec verdict n_leak=0 n_herm=0 n_skip=0 n_to=0 n_vac=0 n_allow=0 n_unmeasured=0
    local human; human=$(mktemp "${TMPDIR:-/tmp}/nrs-human-XXXXXX")
    local recs;  recs=$(mktemp "${TMPDIR:-/tmp}/nrs-recs-XXXXXX")

    say "# nexus-root-sensitivity: PRESENT-TENSE property probe"
    say "# suites: ${#suites[@]}   timeout: ${TIMEOUT_SECS}s   loadavg: $(loadavg)"

    # The sentinel exists because `probe_one` runs inside a command
    # substitution: an `exit` in there ends only the subshell.
    export NRS_ABORT_SENTINEL="${NRS_ABORT_SENTINEL:-$(mktemp "${TMPDIR:-/tmp}/nrs-abort-XXXXXX")}"
    rm -f "$NRS_ABORT_SENTINEL"

    local s
    for s in "${suites[@]}"; do
        # A path that is not there was never measured. Counted, not skipped
        # past with a friendly line — an unexamined suite silently dropped from
        # the denominator is how a run of nothing reads as a run of clean.
        [ -f "$s" ] || {
            say "NOT MEASURED: $s (no such file)"
            n_unmeasured=$((n_unmeasured+1))
            printf '%s\tNOT-MEASURED\t-\t(no such file)\t0\t-\n' "$s" >> "$recs"
            continue
        }
        exec 3>>"$human"
        rec=$(probe_one "$s")
        exec 3>&-
        if [ -e "$NRS_ABORT_SENTINEL" ]; then
            cat "$human"
            say ""
            say "ABORTED: a probe wrote into the operator's REAL state (see FATAL above)."
            say "Refusing to continue — fix the isolation before trusting any verdict."
            rm -f "$human" "$recs" "$NRS_ABORT_SENTINEL"
            return 2
        fi
        # An empty record means probe_one bailed before producing a verdict —
        # mktemp failed, or the decoy could not be built. Same rule: that is
        # NOT MEASURED, and it must not vanish from the accounting.
        if [ -z "$rec" ]; then
            say "NOT MEASURED: $s (probe could not run — decoy or tempdir failure)"
            n_unmeasured=$((n_unmeasured+1))
            printf '%s\tNOT-MEASURED\t-\t(probe could not run)\t0\t-\n' "$s" >> "$recs"
            continue
        fi
        printf '%s\n' "$rec" >> "$recs"
        verdict=$(printf '%s' "$rec" | cut -f2)
        case "$verdict" in
            LEAK) n_leak=$((n_leak+1)) ;; hermetic) n_herm=$((n_herm+1)) ;;
            ALLOWED) n_allow=$((n_allow+1)) ;;
            SKIP) n_skip=$((n_skip+1)) ;; TIMEOUT) n_to=$((n_to+1)) ;;
            VACUOUS) n_vac=$((n_vac+1)) ;;
        esac
    done

    cat "$human"
    say ""
    say "=== nexus-root-sensitivity summary ==="
    local n_measured=$(( n_leak + n_herm + n_allow ))
    local n_noevidence=$(( n_skip + n_to + n_vac + n_unmeasured ))
    printf 'requested: %s   MEASURED: %s   (leaked %s, allowed-by-marker %s, hermetic %s)\n' \
           "${#suites[@]}" "$n_measured" "$n_leak" "$n_allow" "$n_herm"
    printf 'no evidence: %s   (skipped %s, timed out %s, vacuous %s, not measured %s)\n' \
           "$n_noevidence" "$n_skip" "$n_to" "$n_vac" "$n_unmeasured"
    if [ "$n_allow" -gt 0 ]; then
        say ""
        say "LEAKING BUT EXEMPTED by an explicit marker (reported, not failed):"
        awk -F'\t' '$2=="ALLOWED" {printf "  %s   rc=%s  %s\n", $1, $3, $4}' "$recs"
    fi
    if [ "$n_leak" -gt 0 ]; then
        say ""
        say "LEAKING suites:"
        awk -F'\t' '$2=="LEAK" {printf "  %s   rc=%s  %s\n", $1, $3, $4}' "$recs"
        say ""
        say "Fix: make the suite control NEXUS_ROOT for its spawns — scrub it"
        say "(unset / env -u) or pin it to the fixture at every spawn call site."
        say "Any spelling that makes this probe hermetic is accepted; if the"
        say "leak is deliberate, add the marker line:"
        say "  # nexus-root-sensitivity: allow-inherited-root — <reason>"
    fi
    if [ "$n_noevidence" -gt 0 ]; then
        say ""
        say "INCOMPLETE: $n_noevidence selected suite(s) produced no evidence."
        say "This run is NOT a clean bill of health for them."
        awk -F'\t' '$2=="VACUOUS"||$2=="SKIP"||$2=="TIMEOUT"||$2=="NOT-MEASURED" \
                    {printf "  %-52s %s\n", $1, $2}' "$recs"
    fi
    rm -f "$human" "$recs"

    # EXIT CODES. The one that matters is 77.
    #
    # A run that MEASURED NOTHING used to print `leaked: 0 ... hermetic: 0` and
    # return 0 — a clean bill of health from zero measurements, issued by the
    # tool built to retire exactly that. `probe /nonexistent/x.sh` was a green.
    # So "measured clean" and "measured nothing" are now different exit states,
    # and the second is never 0.
    #
    #   0  every measured suite is clean AND at least one was measured
    #   1  at least one leak (an ALLOWED marker does not count)
    #   2  aborted — a probe wrote into the operator's real state
    #   3  partially measured: some evidence, some suites produced none
    #   77 NOT MEASURED: no suite produced any evidence at all
    if [ "$n_leak" -gt 0 ]; then return 1; fi
    if [ "$n_measured" -eq 0 ]; then
        say ""
        say "NOT MEASURED: no suite produced any evidence. This is NOT a pass —"
        say "it is the absence of a measurement, and it exits 77 so it cannot be"
        say "mistaken for one."
        return 77
    fi
    if [ "$n_noevidence" -gt 0 ]; then return 3; fi
    return 0
}

# ---------------------------------------------------------------------------
# self-test — NON-VACUITY. The instrument is run against a KNOWN POSITIVE and a
# KNOWN NEGATIVE before any of its zeros are quotable.
#
# This is the check #655 round 12 skipped and then named as the round's own
# lesson: it shipped 28 clean greens from a detector that was blind to the
# member everyone already knew about. A zero from an instrument whose firing
# rate nobody measured is not evidence.
#
# The known positive is deliberately a suite that is GREEN while leaking, so
# the test proves the detector sees what a PASS/FAIL diff cannot.
# ---------------------------------------------------------------------------
cmd_self_test() {
    local victim="$REPO_ROOT/monitor/watcher/test-worker-nproc-bound.sh"
    [ -f "$victim" ] || die "known positive $victim is missing — self-test cannot run"

    # NOT `local`: the EXIT trap fires after this function's scope is gone, and
    # a trap body referencing a dead local aborts under `set -u` — leaving the
    # mutant behind in the real test directory, where the CI discovery glob
    # would pick it up. (Observed; that is why this is a global.)
    NRS_MUTANT="$REPO_ROOT/monitor/watcher/test-zz-nrs-selftest-mutant.sh"

    # Known positive: the fourth member with its scrub reverted. Written into
    # the real test dir because the suite resolves its own directory to find
    # spawn-worker.sh; removed in the trap.
    sed 's/^unset NEXUS_ROOT$/: # scrub removed by nexus-root-sensitivity self-test/' \
        "$victim" > "$NRS_MUTANT" || die "could not build mutant"
    trap 'rm -f "${NRS_MUTANT:-}"' EXIT INT TERM

    local mutant="$NRS_MUTANT"
    if grep -qE '^unset NEXUS_ROOT$' "$mutant"; then
        die "mutant still scrubs — the sed did not apply, self-test would be vacuous"
    fi

    say "# self-test: the detector against a known positive and a known negative"
    say "# loadavg: $(loadavg)"
    say ""

    exec 3>&1
    say "[1/2] KNOWN POSITIVE — $(basename "$victim") with its scrub removed"
    local rec_pos; rec_pos=$(probe_one "$mutant")
    say "[2/2] KNOWN NEGATIVE — $(basename "$victim") unmodified"
    local rec_neg; rec_neg=$(probe_one "$victim")
    exec 3>&-

    local v_pos rc_pos t_pos v_neg
    v_pos=$(printf '%s' "$rec_pos" | cut -f2); rc_pos=$(printf '%s' "$rec_pos" | cut -f3)
    t_pos=$(printf '%s' "$rec_pos" | cut -f4)
    v_neg=$(printf '%s' "$rec_neg" | cut -f2)

    say ""
    say "=== self-test result ==="
    printf 'known positive : verdict=%s rc=%s tally=[%s]\n' "$v_pos" "$rc_pos" "$t_pos"
    printf 'known negative : verdict=%s\n' "$v_neg"
    say ""

    local ok=0
    if [ "$v_pos" = LEAK ] && [ "$rc_pos" = 0 ]; then
        say "PASS: the detector FIRED on a suite that exited 0 with every"
        say "      assertion passing. That is the sensitive-but-green case, and"
        say "      it is invisible to every PASS/FAIL diff in this repo."
    elif [ "$v_pos" = LEAK ]; then
        say "WARN: the known positive was RED (rc=$rc_pos), so this run shows"
        say "      only that the detector fires — not that it catches the GREEN"
        say "      case, which is the one output-based detectors miss."
    elif [ "$v_pos" = VACUOUS ]; then
        say "FAIL: the probe was VACUOUS on the known positive — the decoy was"
        say "      incomplete, so the spawn died before it could leak. This says"
        say "      nothing about the detector. Fix the decoy, not the verdict."
        ok=1
    elif [ "$rc_pos" != 0 ]; then
        # INCONCLUSIVE, and the distinction is load-bearing. On a GitHub runner
        # the mutant lands in the RED cell of #655's 2x2: no node_modules/
        # (gitignored) and no `claude` on PATH, so `_claude-bin.sh` finds
        # nothing, the spawn exits non-zero, and NOTHING IS EVER WRITTEN. A
        # detector cannot be shown blind against a positive that never emitted
        # a signal — that would be reading "the environment could not stage the
        # experiment" as "the instrument failed", which is the same
        # proxy-for-the-property error this whole issue is about.
        #
        # Exit 77 = SKIP, the repo's "declined to run, NO EVIDENCE" convention
        # (#568 A6). Never 0: this is not a pass. The synthetic equivalents in
        # test-nexus-root-sensitivity.sh cover the same property with fixtures
        # that leak regardless of environment, and those DO run in CI.
        say "INCONCLUSIVE: the known positive did not run green — it exited"
        say "      rc=$rc_pos with [$t_pos], so no spawn occurred and there was"
        say "      no leak for the detector to miss. This environment cannot"
        say "      stage the sensitive-but-green case (a runner has neither"
        say "      node_modules/ nor claude on PATH, so the spawn fails first)."
        say "      NOT a pass and NOT a demonstration of blindness."
        return 77
    else
        say "FAIL: the known positive ran GREEN and the detector did not fire."
        say "      It is blind — the exact failure this self-test exists for."
        ok=1
    fi
    if [ "$v_neg" != hermetic ]; then
        say "FAIL: the known NEGATIVE did not come back hermetic (got $v_neg)."
        say "      The detector cannot distinguish; its positives are worthless."
        ok=1
    else
        say "PASS: the known negative came back hermetic — the detector"
        say "      discriminates rather than firing on everything."
    fi
    return $ok
}

# ---------------------------------------------------------------------------
main() {
    [ "$#" -ge 1 ] || die "usage: $PROG {probe|band|audit|spellings|self-test} [...]"
    local sub="$1"; shift
    local -a rest=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout) TIMEOUT_SECS="$2"; shift 2 ;;
            --log)     AUDIT_LOG="$2"; shift 2 ;;
            --no-verify) VERIFY=0; shift ;;
            --keep-decoy) KEEP_DECOY=1; shift ;;
            --) shift; rest+=("$@"); break ;;
            *) rest+=("$1"); shift ;;
        esac
    done
    case "$sub" in
        probe)
            [ "${#rest[@]}" -gt 0 ] || die "probe needs at least one suite path"
            run_probes "${rest[@]}" ;;
        band)
            if [ "${#rest[@]}" -gt 0 ]; then run_probes "${rest[@]}"
            else
                local -a all; mapfile -t all < <(fixture_suites)
                [ "${#all[@]}" -gt 0 ] || die "no fixture-building suites discovered"
                run_probes "${all[@]}"
            fi ;;
        audit)      cmd_audit ;;
        spellings)  cmd_spellings "${rest[@]}" ;;
        self-test)  cmd_self_test ;;
        *) die "unknown subcommand '$sub'" ;;
    esac
}

main "$@"
