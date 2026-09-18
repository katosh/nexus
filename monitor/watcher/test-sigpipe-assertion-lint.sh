#!/usr/bin/env bash
# test-sigpipe-assertion-lint.sh — no shell source in this repo may test a
# string by piping it into `grep -q`.
#
# THE DEFECT, WITH THE RECEIPT. `grep -q` exits the instant it matches, without
# draining its input. The writer upstream then gets EPIPE (or SIGPIPE), and
# under `set -o pipefail` that non-zero status becomes the PIPELINE's status —
# so the pipeline reports FAILURE at the exact moment the thing it was testing
# turned out to be TRUE. The verdict is inverted by a race, and the race is
# won more often under load.
#
# It is not hypothetical and it is not confined to big strings. From the
# your-org/nexus-code#598 merge run on `dev` (job "unit suite (zsh, jobs 4)",
# first-run artifact), monitor/test-interactive-sessions.sh line 198:
#
#     monitor/test-interactive-sessions.sh: line 198: printf: write error: Broken pipe
#     FAIL  T8b: block present case — got: ## Intro\n\nSome text.
#     <!-- interactive-sessions:start -->
#     ## v2
#     <!-- interactive-sessions:end -->
#
# Read the dump: v2 present, v1 gone, non-block content preserved. The awk
# upsert under test was CORRECT. The suite went red anyway, on a ~90-byte
# payload, because the assertion idiom failed — and the very same test passed
# on the serial re-run. A permanently-flaky red cell is worse than no cell: it
# trains everyone to discount the board.
#
# WHY A LINT AND NOT A ONE-LINE FIX. There were 36 instances of the idiom
# across 18 files when this was written, seven of them in monitor/spawn-worker.sh
# and others in monitor/lit.sh, monitor/cc-auto-update-apply.sh and the
# PreToolUse hooks — production paths, not just tests, where a spuriously
# non-zero `if` silently takes the wrong branch. Converting them once without
# a lint would leave the idiom just as reachable for the next author.
#
# THE FIX, AND WHY IT IS TOTAL. `grep -q PATTERN <<<"$var"` has no pipe, so no
# reader can close one. It is also shorter. There is no case in this repo where
# the pipe form was needed.
#
# COVERAGE BOUNDARY, WRITTEN FROM THE PREDICATE RATHER THAN FROM THE INTENT.
# This lint covers any producer piped into an early-exiting `grep` reader under
# monitor/. It is PRODUCER-AGNOSTIC by design: the hazard is the READER, not
# the writer. `grep -q` exits on first match without draining, and `pipefail`
# promotes the writer's EPIPE to the pipeline's status no matter what wrote the
# bytes (your-org/nexus-code#622).
#
# The READER side is NOT agnostic, and this sentence used to pretend it was.
# It promised "ANY producer piped into `grep` with a `q` flag" while the regex
# matched only a BARE `grep` immediately after the pipe carrying a SHORT `q`
# flag. Six spellings squarely inside that promise evaded it, every one of them
# measured to carry the hazard — match on line 1 of a 200 001-byte payload
# under `set -uo pipefail`, status consumed, `rc=141` on a string that DOES
# match, for all six (your-org/nexus-code#1029). A declared gap is a boundary;
# an undeclared one is a false promise, and the promise is what the next author
# reads before deciding whether their construct is covered.
#
# So the covered set is now ENUMERATED, and every member of it is planted as a
# control in case 3 — the enumeration is asserted by execution, not by prose:
#
#   READER SPELLINGS COVERED
#     grep -q, -qF, -Fq, -qE …      short flags, `q` anywhere in the cluster
#     grep --quiet, grep --silent   long options
#     command|builtin|exec|env|nice|stdbuf grep -q      command-word prefixes
#     /bin/grep -q, ./tools/grep -q                     any path-qualified grep
#     LC_ALL=C grep -q              any run of VAR=val assignment prefixes
#     "$REAL_GREP" -q, $grepbin -q  a VARIABLE command word whose name mentions
#                                   grep, quoted or not (#1372)
#     …and any combination (`| LC_ALL=C command /bin/grep --quiet`)
#   PIPE SPELLINGS COVERED
#     cmd | grep -q                 same line
#     cmd \ ⏎ | grep -q             producer on the PREVIOUS line (#630)
#     cmd | ⏎ grep -q               READER on the NEXT line (trailing pipe)
#     cmd |& grep -q                bash's `2>&1 |`
#
# The trailing-pipe form is the mirror image of the `\`-continuation `#630`
# closed, and it was left open for exactly as long because a same-line matcher
# structurally cannot express it. It is the only member needing more than a
# regex: the scan keeps the previous line and pairs a line ending in exactly
# ONE trailing pipe with a following line that OPENS with a covered reader.
# `||` at end of line is excluded — a `||`-joined pair of herestring greps
# split across lines is the prescribed SAFE form, not a pipe into grep, and
# case 3 plants it as a negative control alongside its same-line twin.
#
# This boundary was redrawn three times, each time because a PROXY stood in for
# the real property — and each proxy let a live instance survive:
#
#   1. By SHAPE (producer). The first sentence described the covered set as "a
#      literal string fed to an early-exiting matcher … with a drop-in
#      redirection replacement" while the regex matched only `printf`. `echo
#      "$var" | grep -q` sat inside the prose and outside the regex; four live
#      instances survived in monitor/watcher/test-bootstrap-phases-dryrun.sh
#      (lines 244/249/254/259, the exact #598 shape). Found by the #616 skeptic.
#   2. By NAME (producer). The regex was then anchored on `(printf|echo|tmux)`
#      AND required the producer token on the SAME line as `| grep`. `tmux` was
#      even in COVERED_PRODUCERS (#630), yet monitor/watcher/main.sh's
#      `tmux capture-pane … \` ⏎ `| grep -qF` survived: a `\`-continuation
#      splits the producer from the pipe, so a same-line anchor never fires. A
#      second `tmux capture-pane` survived identically in _test_helpers.sh.
#      Both are window reads — the "the window does not exist at the moment it
#      does" class #625 claimed to have closed everywhere. Found by re-deriving
#      on the hazard (#622 wrap-up), not by this lint.
#   3. By EXTENSION (file selection). The scan globbed `--include='*.sh'`, but
#      monitor/ng is extensionless and runs `set -uo pipefail`. It carried FOUR
#      live sites — the `tmux list-windows … | grep -Fxq` window-status shape
#      this issue names as dominant, plus two `printf … | grep -qF` (the #616
#      builtin shape) in the dashboard/identity upserts and the skeptic-liveness
#      check — none of which any `.sh` glob could ever see. Worse, the "the
#      monitor/ scan shows only the fixtures" claim used the SAME `.sh` proxy as
#      the lint it was checking, so it confirmed the blind spot instead of
#      finding it. Found by the #622 skeptic.
#   4. By FILE TYPE (case 2b). Enumerating by shebang is right for code and
#      makes one category structurally invisible: PRESCRIPTIVE shell inside a
#      NON-shell file. monitor/services.registry.example recommended
#      `curl -fsS … | grep -q '<marker>'` as the preferred healthcheck body
#      assertion — invisible twice over (no shebang, so not in _shell_files;
#      and a comment line, so dropped by the comment filter even if it were).
#      A doc is worse than a latent site: it is a TEMPLATE, and it propagates
#      the class by being followed. Healthchecks are the costliest place for
#      it — the inverted verdict restarts a HEALTHY service — and an HTTP body
#      routinely exceeds curl's 4 KB stdio chunk, so the producer-emits-past-
#      the-match condition holds by default rather than by accident.
#
# The lesson all four times: a boundary keyed on any proxy — the producer's
# shape, its name, its line position, the file's extension, OR the file's
# type — is a boundary that a member of the class can slip past. The property
# is (reader is early-exiting `grep -q`) × (the text is shell someone runs or
# copies), so the regex matches the reader alone; _shell_files enumerates by
# CONTENT (shebang) plus the SOURCED dotfiles that have neither an extension nor
# a shebang (monitor/shellenv/.zsh*, `*.sh.in`); and _doc_files is the
# COMPLEMENT, not a third extension list — enumerating docs by `*.md -o *.example
# -o …` would have been proxy #6, and it demonstrably had a hole. Only
# _NOT_SHELL_NOT_DOC (other languages + recorded fixtures) is hand-maintained,
# and case 2b(d) asserts it is both load-bearing and SOUND (nothing it drops
# carries a shell shebang) — the one place a blind spot can still be created.
# THREE shapes are deliberately NOT flagged because they carry no pipe into
# grep: the safe replacement `grep -q … <<<"…"`; a `||`-joined herestring
# (`… <<<"…" || grep -qF … <<<"…"`) whose `||` a naive `\| *grep` misreads as a
# pipe; and that same `||`-joined pair SPLIT ACROSS LINES, which the
# trailing-pipe pass must not mistake for a pipe continuation. Case 3 asserts
# all three stay green, plants every reader spelling the boundary above
# enumerates, and plants both a `\`-continuation and an extensionless shebang
# script to prove the two non-regex proxies are gone.
#
# WHO OWNS WHAT. Two files touch this defect; say plainly what each is FOR,
# because "two guards over one idiom" is otherwise indistinguishable from a
# duplicated claim nobody owns:
#
#   * THIS FILE is the REINTRODUCTION guard: does `<any producer> | grep -q`
#     appear anywhere under monitor/? Deliberately dumb — a producer-agnostic
#     grep with named exemptions and planted controls.
#   * monitor/watcher/test-tmux-lookup-sigpipe.sh is the EQUIVALENCE proof for
#     the `tmux` conversion (your-org/nexus-code#622, PR #625): it runs the old
#     and new forms against the same stubbed tmux and requires them to agree on
#     eight legitimate cases and to diverge only on the defect. It carries its
#     own no-pipe guard, so this file's coverage of the tmux idiom is
#     BELT-AND-BRACES. Neither is a live hole if the other is absent.
#
# THE ROOT IS AN ENUMERATION AXIS TOO (your-org/nexus-code#686). Every
# enumerator above is rooted at `find monitor …`, so shell OUTSIDE monitor/ is
# structurally invisible to this lint. That is a deliberate scope, not an
# oversight — but it was asserted nowhere, which is the same shape as the five
# proxies this header already enumerates, one level up: a set someone believed
# was complete, with nothing in the repo saying where it stops.
#
# Outside the root, swept by CONTENT (shebang) rather than by extension —
# enumerating by `*.sh` would be the same proxy this file exists to reject, and
# it demonstrably has a hole: two of the four are EXTENSIONLESS and #686's own
# list missed both.
#
#     config/load.sh
#     experiments/controlled-stall.sh
#     nexus                             <- extensionless, not named in #686
#     watcher                           <- extensionless, not named in #686
#
# All four are CLEAN of `<producer> | grep -q` as of #686, and so are the
# `run:` blocks of .github/workflows/*.yml. Clean is not covered: nothing
# guards them, so the next `config/*.sh` to acquire the idiom under `pipefail`
# inherits the defect silently. Extending the root is a real option and was
# weighed; the workflow `run:` blocks are a genuinely different parsing problem
# (shell embedded in YAML scalars) and must NOT be smuggled into the same
# regex — they need their own extractor and their own controls.
#
# WHAT IS STILL NOT COVERED, AND WHY. First, a DIFFERENT early-exit reader:
# `cmd | head`, `cmd | grep -m1`. They exit before draining exactly as
# `grep -q` does and carry the identical hazard, but they are a wider class the
# repo has not swept — documented-unlinted, not converted. This is a READER
# boundary (which matcher), not a producer boundary: do not let a future edit
# narrow it back onto the writer.
#
# Second — and named here because the previous wording implied otherwise — a
# reader the SOURCE TEXT does not spell as `grep`:
#
#     $notgrep -q                      the command word is a variable whose NAME
#                                      does not mention grep ("$GREP" -q and
#                                      $grepbin -q ARE covered since #1372)
#     eval "… | grep -q …"             the pipeline is built at runtime
#     alias g='grep -q'                the reader is renamed
#     xargs grep -q, find -exec grep -q      the reader is an argument
#     egrep|fgrep|zgrep|rg|ug -q       a grep VARIANT, not `grep`
#
# The variant row is a DECLARED boundary rather than a hidden hole: measured at
# `3458180`, `git grep -nE '\|[[:space:]]*(e|f|z)grep[[:space:]]+-[A-Za-z]*q'
# -- monitor` returns zero, so nothing under monitor/ uses one today. Widening
# to them is cheap and defensible the moment one appears; asserting coverage of
# them while the regex says `grep` is what this block exists to prevent.
#
# A seventh spelling will always exist. That is precisely why the ENUMERATION
# in COVERAGE BOUNDARY — planted, executed, one control per member — is the
# contract, and the regex is only its current implementation.
#
# THE CONVERSION CLAIM, RE-DATED. `#622` said "every `<producer> | grep -q`
# under monitor/ is converted", and that was true of the spellings its regex
# could see. Widening the matcher for `#1029` immediately surfaced TWO live
# sites that had been sitting inside the boundary SENTENCE and outside the
# PREDICATE the whole time — neither is a plant:
#
#     monitor/remote-forced-command.sh:410              | LC_ALL=C grep -q
#     monitor/watcher/test-tmux-window-resolver.sh:784  | LC_ALL=C command grep -q
#
# BOTH ARE DEFENCE IN DEPTH, NOT LIVE FAIL-OPENS. This block first claimed the
# `remote-forced-command.sh` site "fails OPEN on a security check". That was
# overstated, and the correction is kept rather than quietly deleted: an
# overstated severity that becomes a lineage's canonical example is worse than
# no example, because it is the sentence everyone then cites.
#
#   * `remote-forced-command.sh:410` is the non-printable-byte refusal on the
#     remote channel's forced command. `set -uo pipefail` IS in scope (line
#     111) and the pipeline's status IS the `if` condition, so an inverted
#     verdict would take the ELSE branch and admit the byte. It cannot fire
#     THERE: three lines above, `case "$CMD" in *$'\n'*) refuse 12 …` rejects
#     any embedded newline and `refuse` exits, so `$CMD` is SINGLE-LINE by
#     construction — and grep must read a COMPLETE LINE before it can match, so
#     a single-line producer never gives it the chance to exit early.
#   * `test-tmux-window-resolver.sh:784` decodes ONE source line, so its payload
#     is a few hundred bytes — orders of magnitude below the pipe buffer the
#     hazard needs. Same conclusion, different reason.
#
# MEASURED on the exact source shape, `set -uo pipefail`, non-printable byte at
# position 1, TEN trials per size — this is a race, so one sample is not a
# measurement and a single point either side of the onset looks like a step it
# is not:
#
#     single-line   1 KB · 70 KB · 200 KB · 2 MB      REFUSED 10/10 (all sizes)
#     multi-line    8 KB · 32 KB · 60 KB              REFUSED 10/10
#     multi-line   65 KB                              ADMITTED  2/10
#     multi-line   70 KB                              ADMITTED  6/10
#     multi-line  100 KB · 200 KB                     ADMITTED 10/10  (rc=141)
#
# So the hazard is real, it requires MULTI-LINE input, and its onset is the
# 64 KiB pipe buffer — a probabilistic transition band, not a threshold. That
# REFINES this issue's own framing: `printf` does keep writing past the match,
# but whether that write BLOCKS long enough to see EPIPE is governed by the
# buffer, so a small multi-line payload is in fact safe here. The durable
# discriminator remains match POSITION — a match on the LAST line can never
# fire, at any size.
#
# The conversion is still right, and that is why these sites are converted
# rather than annotated: what protects line 410 is a newline refusal three
# lines away, belonging to a different concern. Move it, weaken it, or copy the
# idiom to a site with no such guard, and the hazard is live with nothing
# saying so. Reverting either conversion, one at a time, reddens case 2 by name
# (measured: rc 1, exactly one `FAIL: sigpipe idiom` each).
#
# So as of #1029 every `<producer> | <covered reader>` under monitor/ —
# production and test, all four pipe spellings — is converted, and (case 2b)
# no non-shell doc under monitor/ PRESCRIBES the piped form. The `| grep -q` text that remains under monitor/ is INTENTIONAL
# fixture material: the equivalence-proof file (blanket-exempt); in THIS
# file, planted idioms explicitly marked with the `grepq-fixture` sentinel; and
# in docs, antipattern quotations marked `grepq-antipattern`. Both markers are
# asserted load-bearing AND narrow, so neither can degrade into a blanket hide.
# What case 2b canNOT see is prose OUTSIDE monitor/ (this repo's top-level docs,
# and any operator's own registry) — it enumerates monitor/ only. The
# enforcement mechanism's OWN detection logic uses the prescribed herestring
# form and carries no pipeline — so this file's self-exemption is sentinel-gated,
# NOT blanket: a future real `| grep -q` added to the lint's logic (as
# _shell_files once had) is unmarked, hence flagged, not hidden.
#
# Run: bash monitor/watcher/test-sigpipe-assertion-lint.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
# SOURCED SHELL WITH NEITHER AN EXTENSION NOR A SHEBANG. A startup dotfile is
# executable shell that `.`-sources into every agent shell, but it carries no
# `.sh` name and — being sourced, not executed — no shebang either, so BOTH of
# _shell_files' arms miss it. monitor/shellenv/{.zshenv,.zshrc,.zprofile,.zlogin}
# are exactly that, and they are load-bearing: they are what puts the `gh`
# wrapper at the front of PATH (your-org/nexus-code#578). `*.sh.in` is the same
# argument for templates — the generated file is shell, so the template is too.
# Named explicitly rather than pattern-guessed, and asserted non-empty below: a
# list that silently stops matching is a blind spot wearing a coverage badge.
_SOURCED_SHELL=( -name '.zshenv' -o -name '.zshrc' -o -name '.zprofile' \
                 -o -name '.zlogin' -o -name '.bashrc' -o -name '.profile' \
                 -o -name '*.sh.in' )
# PRUNE THE RUNTIME STATE DIRECTORY, in every walk below
# (your-org/nexus-code#1487, sibling sweep). `monitor/.state/` is gitignored
# runtime state, never source, and it GROWS for as long as a nexus runs.
# Measured 2026-09-08, `find monitor -type f | wc -l` under bash:
#
#     primary clone   26,863 files — of which 26,048 (97%) are monitor/.state
#     fresh clone        810 files — of which 3
#
# This probe opens every non-`.sh` file to read its shebang, so on the primary
# it was opening ~26,000 runtime files and TIMED OUT at rc 124 — the same
# "refused only where operators are" shape as #1487's own subject, arrived at
# from a different cause (that one walks `.` and meets `work/`; this one walks
# `monitor` and meets `.state`).
#
# THE CLASS WAS ALREADY KNOWN HERE AND FIXED ONE INSTANCE AT A TIME: the
# `! -name '.zcompdump*'` below excludes zsh's gitignored completion cache
# because admitting it made `guards-for-diff --run` REFUSE at rc 2. `.state` is
# that same fact at 26,048 files instead of one, so it is pruned as a
# DIRECTORY rather than named as another special case.
_PRUNE_STATE=( -path 'monitor/.state' -prune -o )
_shell_files() {   # emits monitor/… paths relative to CWD
    { find monitor "${_PRUNE_STATE[@]}" -type f \( -name '*.sh' -o -name '*.zsh' -o -name '*.bash' \
          -o "${_SOURCED_SHELL[@]}" \) -print;
      find monitor "${_PRUNE_STATE[@]}" -type f ! -name '*.sh' ! -name '*.zsh' ! -name '*.bash' \
           ! -name '.zcompdump*' -print0 \
        | while IFS= read -r -d '' _f; do
            # `.zcompdump*` is EXCLUDED before the shebang probe: it is zsh's
            # completion cache, written into monitor/shellenv/ (ZDOTDIR) by any
            # zsh that starts while a suite runs, and gitignored. Admitted, it
            # joined the DECLARED population as a transient — a `guards-for-diff
            # --run` concurrent with a full band was REFUSED (rc 2) because the
            # path existed at enumeration and was gone at the existence check
            # (your-org/nexus-code#1378, W2-20). A cache is not a file this lint
            # reads for shell content; naming it as read was the defect.
            # The mechanism obeys its own rule: the shebang test is the prescribed
            # herestring form, NOT `head … | grep -q`. That pipeline was the FOURTH
            # proxy in this lineage (pipefail-file → producer-name → file-glob → the
            # enforcement mechanism re-instantiating the banned class), hidden by a
            # blanket self-exemption. your-org/nexus-code#622 skeptic, round 2.
            # your-org/nexus-code#1347. The herestring stays -- see above, it is
            # the prescribed form and this fix is compatible with that rule --
            # but its SUBJECT is no longer a command substitution. `$( … )`
            # cannot carry a NUL, so a binary under monitor/ made bash warn
            # `ignored null byte in input` and yielded a mangled value; and
            # `head -1` on a binary with no early newline reads the WHOLE file.
            # `IFS= read -r -n 200` has no substitution, cannot be truncated by
            # a NUL, and is BOUNDED -- which is exactly what the shared
            # predicate already does at monitor/shell-files.sh:177. Measured on
            # a planted binary whose first line holds a NUL: the old form warns,
            # this one does not, and both yield the same 12-char value.
            IFS= read -r -n 200 _first < "$_f" 2>/dev/null || _first=''
            grep -qE '^#!.*(bash|zsh|/sh$|/sh |env (ba|z)?sh)' \
              <<<"$_first" && printf '%s\n' "$_f";
          done;
    } | sort -u
}
# _doc_files is the COMPLEMENT, not another extension list. Enumerating docs by
# `*.md -o *.example -o …` would have been the SIXTH proxy — the identical
# mistake at one remove, and it demonstrably had a hole: it missed the sourced
# zsh dotfiles above, `*.conf`, and `*.sh.in`. So the partition is made TOTAL
# instead: every file under monitor/ is a shell file, a doc, or explicitly
# declared NEITHER. Only the "neither" set is a list, it is small, it is
# justified per entry, and case 2b(d) asserts the partition covers everything.
#
# NEITHER = other languages (a `| grep -q` inside them does not run under the
# caller's shell pipe-failure option, so it is not this hazard) and recorded
# fixtures (terminal captures are RECORDINGS, not prescriptions — flagging them
# would train people to ignore the guard).
_NOT_SHELL_NOT_DOC='\.(py|pl|jq|awk|json|tsv|ansi|gitignore)$|/ci-bash-version$'
_doc_files() {   # every file _shell_files does NOT claim and that is not declared NEITHER
    local _sh; _sh=$(_shell_files)
    find monitor "${_PRUNE_STATE[@]}" -type f -print | sort -u | while IFS= read -r _f; do
        grep -qxF "$_f" <<<"$_sh" && continue
        [[ "$_f" =~ $_NOT_SHELL_NOT_DOC ]] && continue
        printf '%s\n' "$_f"
    done
}

# --- the `--population` protocol (your-org/nexus-code#803, #1193) ---------
#
# THIS LINT WAS BYTE-IDENTICAL AND GREEN THROUGHOUT AND STILL MISSED A REAL
# VIOLATION — and nothing malfunctioned. `#1171` added a violating file
# straight past it because the lint declared no population and was therefore
# INVISIBLE to `ng guards-for-diff`: absent from SELECTED and from CONSIDERED
# AND EXCLUDED alike, for a diff whose defining feature was a violation of
# this very lint, while ten other guards were selected and all ten passed at
# rc 0. The author got a clean answer from the tool this repo prescribes for
# exactly that gap. A green guard describes the population it has SEEN, never
# the world; declaring the population is what makes those the same question
# for a diff the index can route here.
#
# THE POPULATION IS THIS GUARD'S OWN ENUMERATORS — never a copy, never a
# hand-typed list of what they return today. A copy is a second
# implementation, and a second implementation drifts, at which point the
# index reports with total confidence that this lint does not read a file it
# does read.
#
# BOTH halves, because the lint scans both: `_shell_files` is the code axis
# and `_doc_files` is its TOTAL complement (case 2b), the two together being
# every file under monitor/ except the explicitly-declared NEITHER set.
# Declaring only the shell half would re-open the #1029 boundary this suite
# already closed, and would leave the doc axis exactly as unroutable as the
# whole lint was before this block.
#
# Both enumerators emit paths relative to CWD, hence the `cd`.
#
# PLACED HERE — above section 1, not merely above the first scan — because
# `gp_handle` EXITS when it handles the flag, so anything printed before it
# lands in the probe's STDOUT and is read as a population row. Measured: with
# this block after the enumerators' original position, the probe emitted four
# lines of section-1 output ahead of 615 real rows, and `gp_render` would
# have refused all four as paths that do not exist. A probe must answer
# without doing the suite's work, and 'without' includes its banners.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    ( cd "$REPO_ROOT" && { _shell_files; _doc_files; } )
}
gp_handle "$@"

# ===========================================================================
# 1. THE PREMISE IS REAL — proven by execution, not asserted in prose.
#
#    The CI occurrence was the racy small-payload variant, which by definition
#    cannot be reproduced on demand. This makes it DETERMINISTIC by supplying
#    the two conditions the race needs: the match is on line 1 (so `grep -q`
#    can exit before reading the rest) and the payload exceeds the pipe buffer
#    (so the writer still has bytes to push when it does). Same mechanism,
#    same inverted verdict; only the timing is forced rather than hoped for.
# ===========================================================================
echo "--- 1. premise: pipefail turns an early grep exit into a FALSE FAILURE ---"
premise=$(bash -c '
    set -uo pipefail
    payload="MATCH_ME"$'"'"'\n'"'"'"$(printf "x%.0s" {1..2000000})"
    printf "%s" "$payload" | grep -q "MATCH_ME"  # grepq-fixture (premise MUST be the pipe form)
    echo "pipe_rc=$?"
    grep -q "MATCH_ME" <<<"$payload"
    echo "herestring_rc=$?"
' 2>/dev/null)
pipe_rc=$(sed -n 's/^pipe_rc=//p' <<<"$premise")
here_rc=$(sed -n 's/^herestring_rc=//p' <<<"$premise")
if [[ "$pipe_rc" != "0" ]]; then
    ok "the pipe form reports FAILURE (rc=$pipe_rc) on a string that DOES match"
else
    bad "premise" "expected the pipe form to report non-zero, got rc=$pipe_rc.
This host did not reproduce the race; the lint below still stands, but this
assertion no longer demonstrates why. Do NOT relax the lint on this basis."
fi
if [[ "$here_rc" == "0" ]]; then
    ok "the herestring form reports SUCCESS (rc=0) on the same string — the fix is total"
else
    bad "premise/fix" "the herestring form returned rc=$here_rc; expected 0"
fi

# ===========================================================================
# 2. THE LINT. No covered producer may pipe into `grep -q` under monitor/.
#
#    The rule is unconditional rather than "…in files that set pipefail":
#    287 of this repo's shell files already set pipefail, and a file that does
#    not today acquires the hazard the moment someone adds `set -o pipefail`
#    at the top — a change no reviewer would connect to a grep forty lines
#    down. An unconditional rule has no such action at a distance.
# ===========================================================================
#    EXEMPTIONS. Two files necessarily CONTAIN the idiom, because they exist to
#    test for it — as executable premises and as planted controls. A lint is a
#    grep over source text and cannot tell a fixture WRITER from a real call
#    site; your-org/nexus-code#625 turned every CI cell red on exactly that.
#    But a WHOLE-FILE exemption is too blunt for THIS file, which is both the
#    fixtures AND the enforcement mechanism: a blanket self-hide let _shell_files
#    keep its own `head … | grep -q` (the #622 round-2 finding). So the two
#    files are exempted DIFFERENTLY — the pure fixture file by path (blanket),
#    this file by a per-line `grepq-fixture` sentinel (narrow) — and each tier is
#    asserted below to be load-bearing, the self tier additionally asserted
#    NARROW (an unmarked pipe-into-grep-q in this file is still flagged).
echo "--- 2. the idiom is absent from monitor/ ---"
# PRODUCER-AGNOSTIC on the writer side; ENUMERATED on the reader side. The full
# covered set, and what is deliberately outside it, is in COVERAGE BOUNDARY —
# and case 3 plants one control per member, so that enumeration is executed
# rather than asserted.
#
# _GREPQ_READER is the READER ALONE, factored out because it is needed in two
# places: after a same-line pipe, and at the start of a line whose predecessor
# ends in a trailing pipe. Sharing one fragment is not tidiness — an earlier
# round of this file validated a COPY of the matcher in its own controls, which
# is one of the two reasons `echo "$var" | grep -q` survived #616. Two
# transcriptions of one idea drift; one fragment used twice cannot.
#
#   (VAR=val|command|builtin|exec|env|nice|stdbuf) …   command-word prefixes,
#                                                       any number, any order
#   ([^…]*/)?                                          path qualification
#   grep                                               the reader, spelled `grep`
#   (-[A-Za-z]*q|--quiet|--silent)                     a quiet flag, either
#                                                       spelling; `q` may sit
#                                                       anywhere in a cluster
#                                                       (`-Fq` and `-qF` both)
#
# `q` is REQUIRED (early-exit), so `grep -c` and a `-q`-less `grep` are
# correctly out — both drain their input and carry no hazard — and so is the
# safe `grep -q … <<<"…"`, which has no pipe at all.
# The command word is either a literal (path-qualified or bare) `grep`, or — since
# your-org/nexus-code#1372 — a VARIABLE whose name contains `grep` in any case,
# quoted or not (`"$REAL_GREP" -q`, `$grepbin -q`): stub-claude-fixtures.sh:109
# piped a `"$REAL_GREP"` writer into a `"$REAL_GREP" -qE` reader and recorded a
# well-formed WRONG value at rc 0, and this lint's boundary had declared that
# spelling out of scope. A variable whose name does not mention grep stays out —
# the lint keys on the source text, and a name that hides the reader is the
# renamed-reader row below, not this one.
_GREPQ_READER='(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|command|builtin|exec|env|nice|stdbuf)[[:space:]]+)*(([^[:space:]|<>&;()"'"'"'`]*/)?grep|"?\$\{?[A-Za-z_]*[Gg][Rr][Ee][Pp][A-Za-z0-9_]*\}?"?)[[:space:]]+(-[A-Za-z]*q|--quiet|--silent)'
# SAME-LINE pipe: `<preceding char that is NOT a pipe>|` and an optional `&`
# (bash's `|&` is `2>&1 |`, and `[[:space:]]*` alone cannot cross the `&`). The
# leading `(^|[^|])` matches a real single pipe while refusing `||` (a
# herestring OR, not a pipe into grep); it needs no producer token on the line,
# so a `\`-continuation `… \` ⏎ `| grep -q` is caught on its `| grep` line.
LINT_RE='(^|[^|])\|&?[[:space:]]*'"$_GREPQ_READER"
# TRAILING-PIPE split: the mirror image, where the pipe ends line N and the
# reader opens line N+1. No single-line matcher can express it, so the scan
# keeps the previous line (see _split_hits). Two halves, both required:
#   _PIPE_EOL_RE   line N ends in exactly ONE pipe (`|` or `|&`), never `||`
#   LINT_RE_SPLIT  line N+1 OPENS with a covered reader
#
# Written with `[|]`, never `\|`. These are handed to awk as DYNAMIC regexes,
# where `\|` is degraded to a plain `|` with a warning — which turns
# `(^|[^|])\|&?[[:space:]]*$` into an alternation whose last branch matches the
# EMPTY STRING at the end of every line, i.e. a predicate that is true
# everywhere. Measured while writing this, on this tree at `3458180`: **274**
# false hits with the backslash spelling, **0** with `[|]`. A guard whose
# precondition is universally true reports its second half as if it were the
# conjunction — the same silent-widening shape this file exists to catch.
_PIPE_EOL_RE='(^|[^|])[|]&?[[:space:]]*$'
# …AND NOT A MARKDOWN TABLE ROW (your-org/nexus-code#1029 follow-up).
# `|` is markdown's column separator, so EVERY row of a table ends in one. The
# doc scan reads markdown, and a table immediately above a shell snippet made
# this pass flag the snippet — including, measured, the lint's OWN PRESCRIBED
# REPLACEMENT:
#
#     | flag | meaning |
#     | --- | --- |
#     | -q | quiet |
#     grep -q needle <<<"$var"        <- the safe form, FLAGGED
#
# That is `#1059` ("procmatch-self fires on the bracketed pattern its own
# message prescribes") reappearing in a different lint hours after its fix
# merged as `#1090`. The cost is not the noise: an author who follows the advice
# and is flagged anyway learns the tag is noise, and skips the NEXT firing,
# which is real. A guard that punishes its own remedy is worse than silent.
#
# A table row is recognised by its LEADING `|` (optionally inside a shell
# comment, since these tables also appear in `#`-prefixed prose). That covers
# the leading-pipe style used throughout this repo and the `| --- | --- |`
# delimiter row. NOT covered, and declared rather than implied: the pipe-less
# GitHub style whose rows happen to end in `|` (`-q | quiet |`), and a genuine
# shell continuation that both starts and ends with a pipe — contrived, and
# case 3 plants the safe form rather than pretending neither exists.
_MD_TABLE_ROW_RE='^[[:space:]]*(#[[:space:]]*)?[|]'
LINT_RE_SPLIT='^[[:space:]]*'"$_GREPQ_READER"

# Two exemption TIERS, because the two files that contain the idiom are not
# alike. test-tmux-lookup-sigpipe.sh is a PURE fixture file (the tmux
# equivalence proof) with no enforcement logic — blanket-exempt by path. THIS
# file is the enforcement mechanism AND its fixtures, so a blanket self-exempt
# would hide a real pipe-into-grep-q slipped into the lint's own logic — exactly
# what happened to _shell_files (your-org/nexus-code#622 round-2 skeptic, the
# fourth proxy in this lineage). So the self-exemption is SENTINEL-GATED: only
# lines carrying `$FIXTURE_SENTINEL` count as intentional fixtures; anything
# else in this file is a finding.
SELF_FILE="monitor/watcher/$(basename "${BASH_SOURCE[0]}")"
FIXTURE_SENTINEL='grepq-fixture'
BLANKET_EXEMPT=(
    "monitor/watcher/test-tmux-lookup-sigpipe.sh"       # #622's tmux equivalence proof — a pure fixture file
)
# One filter, shared by case 2, the load-bearing checks and the narrow proof, so
# they all exercise the SAME exemption logic (not a copy — the #616 lesson).
_apply_exemptions() {
    local line f b
    while IFS= read -r line; do
        f=${line%%:*}
        for b in "${BLANKET_EXEMPT[@]}"; do [[ "$f" == "$b" ]] && continue 2; done
        if [[ "$f" == "$SELF_FILE" ]]; then
            [[ "$line" == *"$FIXTURE_SENTINEL"* ]] && continue   # a marked fixture in this file
        fi
        printf '%s\n' "$line"
    done
}
# Whole-line comments are dropped, matching monitor/watcher/test-tmux-lookup-sigpipe.sh
# so the two guards treat prose the same way. monitor/watcher/_lib.sh documents
# a PRIOR fix in this very family ("The earlier implementation piped `tmux
# list-windows … | grep -qxF`, which masked tmux's own exit status behind
# grep's") — a lint that flags its own documentation trains people to ignore
# it. A trailing comment on a code line is still flagged, deliberately
# conservative. Case 2c proves this is a filter and not a hole.
# A shell script is identified by CONTENT, not by a `.sh` extension. The
# extension is a proxy: monitor/ng is extensionless and runs `set -uo pipefail`,
# so the original `--include='*.sh'` glob structurally could not see it — and it
# carried FOUR live sites, including the `tmux list-windows … | grep -Fxq`
# window-status shape this issue names as dominant, plus two `printf … | grep
# -qF` (the #616 builtin shape) in the dashboard/identity upserts. Found by the
# your-org/nexus-code#622 skeptic; the "monitor/ scan showed only the fixtures"
# claim was false because the scan reused the lint's own `.sh` proxy. So the
# scan now enumerates every `*.sh|.zsh|.bash` file AND every extensionless file
# whose first line is a sh/bash/zsh shebang.
# `_SOURCED_SHELL` and `_shell_files` are defined near the TOP of this file,
# not here, so the `--population` probe can call them before the suite does
# any work (your-org/nexus-code#1193). Only their position changed.
# The TRAILING-PIPE pass. `awk` and not a second `grep`, because the predicate
# spans two lines and no single-line matcher can express it — which is exactly
# why this member of the covered set outlived the other five. Reported at the
# READER's line, matching the same-line pass's convention of naming where the
# early-exiting reader is, so both passes point at the thing to rewrite.
#
# `prevpipe` is reset at FNR==1 so a trailing pipe on the last line of one file
# cannot pair with the first line of the next.
_split_hits() {   # $@ = files
    # Two guards on the PREVIOUS line, both about telling a pipe from something
    # that merely ends in the same character:
    #   * a markdown table row is not a pipe continuation (see _MD_TABLE_ROW_RE);
    #   * a whole-line COMMENT does not continue a pipeline into CODE. Prose
    #     cannot pipe into the next statement. Comment-to-comment still pairs,
    #     which is what keeps a doc that PRESCRIBES the split form in scope
    #     (case 2b's whole subject), and code-to-code is untouched.
    awk -v rdr="$LINT_RE_SPLIT" -v pend="$_PIPE_EOL_RE" -v mdrow="$_MD_TABLE_ROW_RE" '
        FNR == 1 { prevpipe = 0; prevcmt = 0 }
        {
            cmt = ($0 ~ /^[[:space:]]*#/)
            if (prevpipe && prevcmt == cmt && $0 ~ rdr)
                printf "%s:%d:%s\n", FILENAME, FNR, $0
            prevpipe = ($0 ~ pend) && ($0 !~ mdrow)
            prevcmt  = cmt
        }
    ' "$@" 2>/dev/null
}
# BOTH passes, one comment filter, one dedup. A line can match both (a same-line
# `| grep -q` whose predecessor also ends in a pipe); `sort -u` makes that one
# finding rather than two, and every consumer below counts findings.
_scan_root() {   # $1 = tree whose monitor/ subtree to scan; grep the shell files
    ( cd "$1" 2>/dev/null || exit 0
      local -a _files; mapfile -t _files < <(_shell_files)
      (( ${#_files[@]} )) || exit 0
      { grep -EHn "$LINT_RE" "${_files[@]}" 2>/dev/null
        _split_hits "${_files[@]}"; } \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | sort -u
    )
}
_lint_scan() { _scan_root "$REPO_ROOT"; }
mapfile -t hits < <( _lint_scan | _apply_exemptions || true )
if (( ${#hits[@]} == 0 )); then
    ok "no unmarked producer-piped-into \`grep -q\` under monitor/ (1 blanket fixture file + this file's \`$FIXTURE_SENTINEL\` fixtures)"
else
    for h in "${hits[@]}"; do
        bad "sigpipe idiom" "$h
    → rewrite as: grep -q PATTERN <<<\"\$var\"  (or <<<\"\$(cmd)\" for a process)"
    done
fi

# (a) Every BLANKET exemption must be load-bearing. One that suppresses nothing
# has stopped matching — the file was renamed, or no longer contains the idiom —
# and case 2 is then not the scan it documents. A dead exemption is a blind spot
# nobody is counting, the shape of defect this whole file exists to prevent.
for _ex in "${BLANKET_EXEMPT[@]}"; do
    mapfile -t _ex_hits < <( _lint_scan | grep "^$_ex:" || true )
    if (( ${#_ex_hits[@]} > 0 )); then
        ok "blanket exemption load-bearing: $_ex suppresses ${#_ex_hits[@]} line(s)"
    else
        bad "exemption/$_ex" "this blanket exemption suppresses NOTHING — the file was
renamed or removed, or it no longer contains the idiom. Drop it."
    fi
done

# (b) The self-exemption must be load-bearing AND narrow. Load-bearing: this
# file's marked fixtures are suppressed, and NOTHING unmarked leaks (an unmarked
# self hit is either a real pipeline in the lint's logic, or a fixture that lost
# its sentinel — both are findings). This is the assertion the blanket self-hide
# could never make; it is why _shell_files' own pipeline went unseen.
mapfile -t _self_all  < <( _lint_scan | grep "^$SELF_FILE:" || true )
mapfile -t _self_kept < <( _lint_scan | grep "^$SELF_FILE:" | _apply_exemptions || true )
_self_suppressed=$(( ${#_self_all[@]} - ${#_self_kept[@]} ))
if (( _self_suppressed > 0 )) && (( ${#_self_kept[@]} == 0 )); then
    ok "self-exemption load-bearing: ${_self_suppressed} \`$FIXTURE_SENTINEL\`-marked fixture line(s) suppressed, 0 unmarked leak"
else
    bad "self-exemption" "of ${#_self_all[@]} matches in this file, ${#_self_kept[@]} are UNMARKED — a real pipeline in the lint's own logic, or a fixture missing its \`$FIXTURE_SENTINEL\` tag:
$(printf '  %s\n' "${_self_kept[@]}")"
fi

# (b) narrow proof, by construction — a gate never seen fail is not evidence.
# The SAME filter must REPORT an unmarked self hit and DROP the marked twin.
_p_unmarked="$SELF_FILE:9999:    if foo | grep -q bar; then :; fi"  # grepq-fixture (this source line; the VALUE is deliberately unmarked)
_p_marked="$_p_unmarked  # $FIXTURE_SENTINEL"
if [[ -n "$(printf '%s\n' "$_p_unmarked" | _apply_exemptions)" \
   && -z "$(printf '%s\n' "$_p_marked"   | _apply_exemptions)" ]]; then
    ok "self-exemption is NARROW: an unmarked pipe-into-grep-q in this file is flagged; only \`$FIXTURE_SENTINEL\` lines are exempt"
else
    bad "self-exemption/narrow" "the self-exemption is not sentinel-gated — an unmarked
pipeline in the lint's own logic would be hidden (the blanket-hide that was the fourth #622 proxy)."
fi

# COVERAGE FLOOR (your-org/nexus-code#622 skeptic). Case 2's green is only
# meaningful over the files the scan actually visits. The whole point of the
# content-based enumeration is that it reaches EXTENSIONLESS shell scripts —
# monitor/ng was the file whose invisibility made the "zero remainder" claim
# false. Assert it positively: the real monitor/ng is in _shell_files. If ng is
# renamed or grows a `.sh`, update this witness; do NOT let the scan quietly
# stop covering extensionless scripts (that is the exact regression this asserts
# against). Paired with case 3's planted violation AT path monitor/ng, this is
# the arm that was structurally impossible before the widening.
mapfile -t _shf < <( cd "$REPO_ROOT" && _shell_files )
_ng_in_scope=0; _extless_count=0
for _f in "${_shf[@]}"; do
    [[ "$_f" == *.sh || "$_f" == *.zsh || "$_f" == *.bash ]] || _extless_count=$(( _extless_count + 1 ))
    [[ "$_f" == "monitor/ng" ]] && _ng_in_scope=1
done
if (( _ng_in_scope == 1 )); then
    ok "coverage floor: monitor/ng (extensionless) is in the scanned set — the #622 blind spot is closed (${_extless_count} extensionless shell scripts scanned)"
else
    bad "coverage floor" "monitor/ng is NOT in the content-based scan (${#_shf[@]} shell files, ${_extless_count} extensionless). Either ng was renamed/removed — update this witness — or _shell_files has regressed to an extension proxy and is blind to extensionless scripts again, which is exactly how four live sites hid until #622."
fi

# ===========================================================================
# 2b. THE DOC AXIS — the FIFTH proxy in this lineage.
#
#     Case 2 enumerates by CONTENT (shebang) and then drops comment lines.
#     Both are right for code, and together they make one whole category
#     structurally invisible: PRESCRIPTIVE shell inside a NON-shell file.
#     monitor/services.registry.example recommended
#     `curl -fsS … | grep -q '<marker>'` as the preferred healthcheck body
#     assertion — invisible TWICE OVER (no shebang, so not in _shell_files;
#     and a comment line, so dropped even if it were). That is not a latent
#     site, it is a TEMPLATE: every operator who follows it instantiates the
#     class in a healthcheck, where the false negative restarts a HEALTHY
#     service. An HTTP body routinely exceeds curl's 4 KB stdio chunk, so
#     condition 3 (the producer can emit past the match) holds by default
#     rather than by accident.
#
#     The lineage: pipefail-file → producer-name → file-glob → the
#     enforcement mechanism itself → and now the FILE TYPE. Every one was a
#     proxy for "what gets scanned" rather than the hazard.
#
#     Exempting by heuristic ("the line says never/avoid") would be a sixth
#     proxy — prose is not parseable. So a doc line that quotes the
#     antipattern to WARN about it must say so with an explicit per-line
#     `grepq-antipattern` marker, the same round-2 lesson that made the
#     self-exemption sentinel-gated. Asserted load-bearing AND narrow below.
# ===========================================================================
echo "--- 2b. prescriptive shell in NON-shell files (docs, examples, registries) ---"
DOC_SENTINEL='grepq-antipattern'
# `_NOT_SHELL_NOT_DOC` and `_doc_files` are defined near the TOP of this file
# for the same reason as `_shell_files` — see the note there. Only their
# position changed; the partition argument is unchanged and travelled with
# them.
# NOTE: no comment-line filter here. In a doc, the snippet IS the payload —
# filtering comments would re-hide the exact site this case exists to catch.
_doc_scan() {
    ( cd "${1:-$REPO_ROOT}" 2>/dev/null || exit 0
      local -a _files; mapfile -t _files < <(_doc_files)
      (( ${#_files[@]} )) || exit 0
      # Same two passes as the code scan. A doc that PRESCRIBES the split form
      # is as much a template for the defect as one prescribing the same-line
      # form; letting the two scans cover different spelling sets would put the
      # doc axis back where COVERAGE BOUNDARY was before #1029.
      { grep -EHn "$LINT_RE" "${_files[@]}" 2>/dev/null
        _split_hits "${_files[@]}"; } | sort -u )
}
_doc_apply() { grep -vF "$DOC_SENTINEL" || true; }
mapfile -t _dochits < <( _doc_scan | _doc_apply )
mapfile -t _docall  < <( cd "$REPO_ROOT" && _doc_files )
if (( ${#_dochits[@]} == 0 )); then
    ok "no unmarked \`… | grep -q\` PRESCRIBED in the ${#_docall[@]} non-shell docs/examples under monitor/ (the fifth-proxy axis: what _shell_files structurally cannot see)"  # grepq-fixture (message text, not a pipeline)
else
    for _h in "${_dochits[@]}"; do
        bad "sigpipe idiom (doc)" "$_h
    → a doc that PRESCRIBES the piped form is a template for the defect, not a
      latent site. Rewrite the recommendation as: grep -q PATTERN <<<\"\$(cmd …)\"
      If this line quotes the antipattern in order to WARN, mark it \`$DOC_SENTINEL\`."
    done
fi
# (a) The doc exemption must be LOAD-BEARING: if it suppresses nothing, the
# warning text was reworded away and this case is no longer the scan it claims.
_doc_raw=$( _doc_scan | wc -l ); _doc_kept=${#_dochits[@]}
if (( _doc_raw > _doc_kept )); then
    ok "doc exemption load-bearing: $(( _doc_raw - _doc_kept )) \`$DOC_SENTINEL\`-marked warning line(s) suppressed, ${_doc_kept} unmarked leak"
else
    bad "doc exemption/load-bearing" "the \`$DOC_SENTINEL\` marker suppresses nothing (raw=$_doc_raw kept=$_doc_kept).
Either the warning in services.registry.example was reworded away — restore a marked
witness — or the doc scan stopped matching, in which case its green means nothing."
fi
# (b) …and NARROW: an UNMARKED prescription in a doc is still flagged.
_d_unmarked='monitor/services.registry.example:9999:#   curl -fsS … | grep -q marker'  # grepq-fixture (this source line; the VALUE is deliberately unmarked)
_d_marked="$_d_unmarked   $DOC_SENTINEL"
if [[ -n "$(printf '%s\n' "$_d_unmarked" | _doc_apply)" \
   && -z "$(printf '%s\n' "$_d_marked"   | _doc_apply)" ]]; then
    ok "doc exemption is NARROW: an unmarked prescription is flagged; only \`$DOC_SENTINEL\` lines are exempt"
else
    bad "doc exemption/narrow" "the doc exemption is not marker-gated — an unmarked
prescription would be hidden, which is the fifth proxy reintroduced."
fi
# (d) PARTITION TOTALITY — the assertion that makes this boundary CHECKABLE
# rather than asserted. Every proxy in this lineage was a set someone believed
# was complete. So do not believe it: recompute shell ∪ doc ∪ declared-neither
# and require it to equal every file under monitor/. A new file type — a `.toml`
# config, a `.template`, a fresh dotfile — lands in NONE of the three and turns
# this red, naming it, instead of silently sitting outside both scans the way
# monitor/ng did for three rounds.
mapfile -t _all_files < <( cd "$REPO_ROOT" && find monitor -type f | sort -u )
mapfile -t _shf2      < <( cd "$REPO_ROOT" && _shell_files )
# The membership tests below are herestrings, NOT `printf … | grep -qxF`.
# Written the piped way first, this block reported all 41 shell files as
# uncovered — `grep -q` exited on the match, SIGPIPE'd `printf`, and `pipefail`
# turned the pipeline's status to 141, so `&& continue` never fired. The
# assertion failed precisely BECAUSE the lookup succeeded. That is this lint's
# own subject reproducing itself inside its enforcement logic for the second
# time (the round-2 `_shell_files` finding was the first), which is the whole
# argument for keeping the self-exemption sentinel-gated instead of blanket.
_shf2_s=$(printf '%s\n' "${_shf2[@]}")
_doc_s=$(printf '%s\n' "${_docall[@]}")
# HONESTY NOTE, kept because deleting it would leave a trap for the next
# author. "No file sits outside both scans" is TRUE but TAUTOLOGICAL: since
# _doc_files is the complement, an unrecognised file type is a doc by
# construction, so a totality assertion here can never fail. Mutation-testing
# it proved exactly that — planting a `monitor/newthing.toml` left the suite
# green. An assertion that cannot fail is not evidence, so it is NOT asserted.
#
# What CAN fail, and is therefore what gets asserted, is the one hand-maintained
# list in the partition: _NOT_SHELL_NOT_DOC. It is the only way a file leaves
# BOTH scans, so it is the only real blind-spot generator — the direct
# descendant of every proxy in this lineage. Two properties, both falsifiable:
#   (i)  it is load-bearing (it excludes something), and
#   (ii) nothing it excludes is actually a shell script.
# (ii) is the one with teeth: widening the list to, say, `\.env$` or `\.tmpl$`
# would silently drop real shell out of case 2, and this reddens naming it.
_excluded=(); _excluded_but_shell=()
for _f in "${_all_files[@]}"; do
    [[ "$_f" =~ $_NOT_SHELL_NOT_DOC ]] || continue
    _excluded+=("$_f")
    # Same NUL-safe probe as the population sweep above (your-org/nexus-code#1347):
    # `$(head -1 …)` on a binary with no early newline reads the whole file and
    # warns per NUL; `IFS= read -r -n 200` has no substitution. This was the
    # second copy of the probe and it was left on the old form when the first
    # was fixed — noted on the W2-20 handover, fixed on the merge.
    IFS= read -r -n 200 _first < "$REPO_ROOT/$_f" 2>/dev/null || _first=''
    grep -qE '^#!.*(bash|zsh|/sh$|/sh |env (ba|z)?sh)' \
        <<<"$_first" && _excluded_but_shell+=("$_f")
done
if (( ${#_excluded[@]} > 0 )); then
    ok "exclusion list load-bearing: _NOT_SHELL_NOT_DOC excludes ${#_excluded[@]} file(s) (other languages + recorded fixtures) of ${#_all_files[@]} under monitor/; shell=${#_shf2[@]} doc=${#_docall[@]}"
else
    bad "exclusion/load-bearing" "_NOT_SHELL_NOT_DOC matches NOTHING. Either the fixtures/other-language
files moved, or the pattern rotted — and a dead exclusion means the doc scan is
silently absorbing files nobody classified."
fi
if (( ${#_excluded_but_shell[@]} == 0 )); then
    ok "exclusion is SOUND: none of the ${#_excluded[@]} excluded files carries a shell shebang — the list drops other languages and fixtures, not shell"
else
    bad "exclusion/soundness" "${#_excluded_but_shell[@]} file(s) excluded by _NOT_SHELL_NOT_DOC are SHELL SCRIPTS:
$(printf '  %s\n' "${_excluded_but_shell[@]}" | head -10)
They carry a shell shebang and are now invisible to case 2. Narrow the pattern —
this is the lineage's defect exactly: a convenient exclusion that quietly
removes real members of the class from the scan."
fi
# …and the sourced-dotfile arm must be LOAD-BEARING. If it matches nothing, the
# files were renamed or moved and case 2 has quietly stopped covering shell that
# every agent shell sources.
_srcd=0
for _f in "${_shf2[@]}"; do
    case "$_f" in */.zshenv|*/.zshrc|*/.zprofile|*/.zlogin|*.sh.in) _srcd=$(( _srcd + 1 )) ;;
    esac
done
if (( _srcd > 0 )); then
    ok "sourced-shell arm load-bearing: ${_srcd} extension-less/shebang-less shell file(s) (zsh dotfiles, *.sh.in) are scanned — neither arm of the old enumeration saw them"
else
    bad "sourced-shell arm" "the _SOURCED_SHELL arm matches NOTHING. monitor/shellenv/.zshenv
and friends are sourced into every agent shell and carry no shebang, so if they
moved, case 2 is blind to them and nothing says so."
fi

# (c) COVERAGE FLOOR for this axis, mirroring case 2's monitor/ng witness: the
# file that carried the real finding must actually be in the doc scan set.
_reg_in_scope=0
for _f in "${_docall[@]}"; do [[ "$_f" == "monitor/services.registry.example" ]] && _reg_in_scope=1; done
if (( _reg_in_scope == 1 )); then
    ok "doc coverage floor: monitor/services.registry.example is in the doc scan set (${#_docall[@]} non-shell files)"
else
    bad "doc coverage floor" "monitor/services.registry.example is NOT in the doc scan (${#_docall[@]} files).
Either it was renamed — update this witness — or _doc_files' extension list no longer
reaches it, and this whole axis is green over nothing."
fi

# ===========================================================================
# 2b(e). THE PASS MUST NOT FIRE ON THE REMEDY IT PRESCRIBES.
#
#     `|` is markdown's column separator, so every row of a table ends in one,
#     and the trailing-pipe pass read a table row as a pipe continuation. The
#     line it then flagged was the lint's OWN PRESCRIBED REPLACEMENT — measured,
#     not hypothesised: `monitor/flags.md:6:grep -q needle <<<"$var"`.
#
#     That is your-org/nexus-code#1059 — "procmatch-self fires on the bracketed
#     pattern its own message prescribes" — recurring in a different lint hours
#     after its fix merged as `#1090`. The cost is not noise. An author who
#     follows the advice and is flagged anyway learns the tag is noise and
#     skips the NEXT firing, which is real.
#
#     So: the exact planted doc is a NEGATIVE control, and a doc that genuinely
#     prescribes the split form is a POSITIVE one — because "stop flagging the
#     table" is satisfiable by disabling the pass, and only the pair rules that
#     out.
# ===========================================================================
echo "--- 2b(e). markdown tables are not pipe continuations ---"
MTMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$MTMP/monitor/watcher"
: > "$MTMP/monitor/watcher/keep.sh"   # so _shell_files is non-empty
cat > "$MTMP/monitor/flags.md" <<'MDSAFE'
# grep flags

| flag | meaning |
| --- | --- |
| -q | quiet |
grep -q needle <<<"$var"
MDSAFE
mapfile -t _md_safe < <( _doc_scan "$MTMP" | _doc_apply )
if (( ${#_md_safe[@]} == 0 )); then
    ok "a markdown table above the PRESCRIBED herestring form is not flagged (#1059's class, not reintroduced)"
else
    bad "markdown table/false positive" "the lint flagged its own prescribed replacement: ${_md_safe[*]}
A table row ends in \`|\` because that is markdown's column separator, not because
it pipes into the next line. Flagging the remedy teaches authors the tag is noise."
fi
# POSITIVE control on the same axis: a doc that really does PRESCRIBE the split
# form must still be caught, or the fix above is indistinguishable from
# switching the pass off.
# WRITTEN WITH printf, NOT A HEREDOC, and that is not a style choice. A heredoc
# body lives in THIS file, so a fixture that WRITES the split form puts a real
# trailing-pipe idiom two lines apart in the lint's own source — and case 2
# caught exactly that while this control was being added
# (`test-sigpipe-assertion-lint.sh:788: grep -q '<marker>'`). Quoting each line
# as a printf argument keeps the fixture bytes identical while leaving no pipe
# at end-of-line here. `test-helper-honesty.sh` records the same manoeuvre for
# the same reason.
printf '%s\n' \
    'Recommended healthcheck body assertion:' \
    '' \
    '    curl -fsS "$url" |' \
    "        grep -q '<marker>'" \
    > "$MTMP/monitor/flags.md"
mapfile -t _md_bad < <( _doc_scan "$MTMP" | _doc_apply )
if (( ${#_md_bad[@]} == 1 )) && [[ "${_md_bad[0]}" == *"flags.md:4:"* ]]; then
    ok "…and a doc that genuinely PRESCRIBES the trailing-pipe form is still caught on its reader line"
else
    bad "markdown table/over-correction" "expected exactly the line-4 hit, got ${#_md_bad[@]}: ${_md_bad[*]:-<none>}
The table exclusion has switched the trailing-pipe pass off for docs instead of
narrowing it — which satisfies the negative control above and covers nothing."
fi
rm -rf "$MTMP"

# 2b(f). PROSE DOES NOT PIPE INTO CODE. The second half of the same narrowing:
# a whole-line comment ending in `|` is a sentence that happens to end in a
# pipe character, and the CODE line after it is not its continuation. Asserted
# with its own positive twin, so this too cannot be satisfied by switching the
# pass off.
echo "--- 2b(f). a comment ending in a pipe does not continue into code ---"
PTMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$PTMP/monitor/watcher"
cat > "$PTMP/monitor/watcher/prose.sh" <<'PROSE'
#!/usr/bin/env bash
set -uo pipefail
# the separator we use is |
grep -q needle <<<"$var"
PROSE
mapfile -t _prose < <( _scan_root "$PTMP" || true )
if (( ${#_prose[@]} == 0 )); then
    ok "a prose comment ending in \`|\` does not make the next CODE line a pipe continuation"
else
    bad "prose/false positive" "flagged a herestring under a comment: ${_prose[*]}"
fi
cat > "$PTMP/monitor/watcher/prose.sh" <<'PROSE2'
#!/usr/bin/env bash
set -uo pipefail
some_producer |
    grep -q needle && echo hit  # grepq-fixture
PROSE2
mapfile -t _prose2 < <( _scan_root "$PTMP" || true )
if (( ${#_prose2[@]} == 1 )) && [[ "${_prose2[0]}" == *"prose.sh:4:"* ]]; then
    ok "…and a REAL trailing-pipe continuation in the same file is still caught"
else
    bad "prose/over-correction" "expected exactly the line-4 hit, got ${#_prose2[@]}: ${_prose2[*]:-<none>}"
fi
rm -rf "$PTMP"

echo "--- 2c. the comment filter drops prose but NOT a real line ---"
CTMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$CTMP/monitor/watcher"
cat > "$CTMP/monitor/watcher/mixed.sh" <<'MIXED'
#!/usr/bin/env bash
# printf '%s' "$b" | grep -q needle    <- prose, must be ignored
if printf '%s' "$b" | grep -q needle; then :; fi  # grepq-fixture
MIXED
mapfile -t _mixed < <( _scan_root "$CTMP" || true )
rm -rf "$CTMP"
if (( ${#_mixed[@]} == 1 )) && [[ "${_mixed[0]}" == *"mixed.sh:3:"* ]]; then
    ok "comment on line 2 ignored, code on line 3 still caught — a filter, not a hole"
else
    bad "comment filter" "expected exactly the line-3 code hit, got ${#_mixed[@]}: ${_mixed[*]:-<none>}
Either the filter swallows real code (a hole) or it fails to drop prose (noise)."
fi

# ===========================================================================
# 3. THE LINT ACTUALLY FIRES — a negative control, matching the MESSAGE.
#
#    Case 2 passing proves only that the grep found nothing; it does not
#    distinguish "the idiom is gone" from "the pattern is broken and would
#    never match anything". A gate never seen fail is not evidence. So plant
#    the idiom in a scratch tree and require the same expression to catch it.
# ===========================================================================
#    EVERY producer converted for #622 is planted, not just the ones that
#    prompted the lint. The regex is producer-AGNOSTIC, so ONE plant would prove
#    it fires — but the observed producer set IS the #622 enumeration, so
#    planting all of it keeps that enumeration executable AND makes the #2
#    regression in COVERAGE BOUNDARY (re-anchoring on a producer name) fail
#    loudly here instead of silently narrowing coverage. An earlier version also
#    hardcoded a `printf`-only regex here instead of reusing $LINT_RE, validating
#    a COPY of the matcher — one of the two reasons `echo "$var" | grep -q`
#    survived. Every scan below runs the live $LINT_RE.
echo "--- 3. negative control: the lint expression catches a planted instance ---"
TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/monitor/watcher"

# One planted file per producer. The default arm handles every producer by
# construction — the regex keys on `| grep -q`, not on the token — so `tr`,
# `ls`, `locale`, `ss`, `sed`, `cat`, `python`, `grep` and a bare function `fn`
# (the producers the old `(printf|echo|tmux)` enumeration never named) all get a
# valid control from it. `printf`/`echo`/`tmux` keep bespoke arms to exercise
# their real idioms.
COVERED_PRODUCERS=(printf echo tmux tr ls locale ss sed cat python grep fn)
plant_for() {
    case "$1" in
        printf) printf 'if printf %s "$body" | grep -q %s; then echo hit; fi\n' "'%s'" "'needle'" ;;  # grepq-fixture
        echo)   printf 'if echo "$body" | grep -qE %s; then echo hit; fi\n' "'needle'" ;;  # grepq-fixture
        # Heredoc, not printf: a `printf '… | grep -q …'` that WRITES a fixture
        # is textually the idiom, so outside this file's exemption it would be
        # a finding rather than a fixture (your-org/nexus-code#625). The arms
        # above are safe only because this file is exempt.
        tmux)   cat <<'TMUXPLANT'
if tmux list-windows -F '#W' 2>/dev/null | grep -qxF "$w"; then echo hit; fi  # grepq-fixture
TMUXPLANT
                ;;
        # Producer-agnostic default: the token is irrelevant, the `| grep -q` is
        # the whole finding. This arm is what proves the lint catches producers
        # the old enumeration never named.
        *)      printf 'if %s arg 2>/dev/null | grep -q needle; then echo hit; fi\n' "$1" ;;  # grepq-fixture
    esac
}
for prod in "${COVERED_PRODUCERS[@]}"; do
    f="$TMP/monitor/watcher/planted-$prod.sh"
    { printf '#!/usr/bin/env bash\nset -uo pipefail\n'; plant_for "$prod"; } > "$f"
    # $LINT_RE itself — NOT a transcription of it. A control that exercises a
    # copy proves nothing about the expression actually guarding the tree.
    mapfile -t planted < <( _scan_root "$TMP" || true )
    if (( ${#planted[@]} == 1 )) && [[ "${planted[0]}" == *"planted-$prod.sh:3:"* ]]; then
        ok "planted \`$prod … | grep -q\` caught at the expected file and line"  # grepq-fixture
    else
        bad "negative control/$prod" "expected exactly 1 hit in planted-$prod.sh line 3, got ${#planted[@]}:
${planted[*]:-<none>}
\$LINT_RE does not match the \`$prod\` form it claims to cover — case 2's green
is meaningless for that producer. This is exactly how \`echo\` survived #616."
    fi
    rm -f "$f"
done

# CONTINUATION-LINE control. The #2 survivor (monitor/watcher/main.sh:2009) was
# a `tmux capture-pane … \` then `| grep -qF` with the producer and the pipe on
# different lines; the old same-line-anchored regex could not see it. Plant that
# exact two-line shape and require the hit on the pipe line (line 4). The old
# lint could not have made this assertion — it is the proof the redraw fixed the
# survivor CLASS, not just the one instance.
cat > "$TMP/monitor/watcher/planted-cont.sh" <<'CONT'
#!/usr/bin/env bash
set -uo pipefail
some_producer --with args 2>/dev/null \
    | grep -qF "$needle" && echo hit  # grepq-fixture
CONT
mapfile -t cont < <( _scan_root "$TMP" || true )
if (( ${#cont[@]} == 1 )) && [[ "${cont[0]}" == *"planted-cont.sh:4:"* ]]; then
    ok "planted continuation-line pipe (producer on the line above) caught on its \`| grep\` line — the #622 survivor shape"
else
    bad "continuation control" "expected exactly the line-4 pipe hit, got ${#cont[@]}:
${cont[*]:-<none>}
A pipe split across a backslash-continuation is invisible to a producer+pipe-
same-line regex — this is how monitor/watcher/main.sh:2009 survived #625/#630."
fi
rm -f "$TMP/monitor/watcher/planted-cont.sh"

# READER-SPELLING controls (your-org/nexus-code#1029). COVERAGE BOUNDARY above
# ENUMERATES the reader and pipe spellings this lint claims. An enumeration
# asserted only in prose is precisely the false promise #1029 is about — the
# old boundary sentence promised "ANY producer piped into `grep` with a `q`
# flag" while SIX spellings inside it evaded the regex, and case 3 planted not
# one of them. So every member of the enumeration is planted here.
#
# Each was first measured to carry the REAL hazard, not merely to match a
# regex: match on line 1 of a 200 001-byte payload, `set -uo pipefail`, status
# consumed. All returned `rc=141` — pipeline FAILURE on a string that DOES
# match. Before the widening exactly ONE of them (`| grep -q`) was reported;
# the other six were silent. If a future edit narrows the matcher, the member
# it drops reddens here by name instead of quietly leaving the boundary a lie.
#
# `<label>|<expected line>|<body>` — `read` puts the remainder, pipes and all,
# in the last field, so the body may contain `|`. `%b` expands `\n`, which is
# how the two-line trailing-pipe plant is written.
READER_SPELLINGS=(
    "short-flag|3|if printf '%s' \"\$b\" | grep -q needle; then :; fi"                            # grepq-fixture
    "short-cluster-qF|3|if printf '%s' \"\$b\" | grep -qF needle; then :; fi"                     # grepq-fixture
    "short-cluster-Fq|3|if printf '%s' \"\$b\" | grep -Fq needle; then :; fi"                     # grepq-fixture
    "long-quiet|3|if printf '%s' \"\$b\" | grep --quiet needle; then :; fi"                       # grepq-fixture
    "long-silent|3|if printf '%s' \"\$b\" | grep --silent needle; then :; fi"                     # grepq-fixture
    "command-prefix|3|if printf '%s' \"\$b\" | command grep -q needle; then :; fi"                # grepq-fixture
    "env-prefix|3|if printf '%s' \"\$b\" | env grep -q needle; then :; fi"                        # grepq-fixture
    "path-qualified|3|if printf '%s' \"\$b\" | /bin/grep -q needle; then :; fi"                   # grepq-fixture
    "var-prefix|3|if printf '%s' \"\$b\" | LC_ALL=C grep -q needle; then :; fi"                   # grepq-fixture
    "combined|3|if printf '%s' \"\$b\" | LC_ALL=C command /bin/grep --quiet needle; then :; fi"   # grepq-fixture
    "amp-pipe|3|if printf '%s' \"\$b\" |& grep -q needle; then :; fi"                             # grepq-fixture
    "trailing-pipe|4|printf '%s' \"\$b\" |\n    grep -q needle && echo hit"                       # grepq-fixture
    "var-quoted|3|if printf '%s' \"\$b\" | \"\$REAL_GREP\" -qE needle; then :; fi"                 # grepq-fixture (#1372)
    "var-bare|3|if printf '%s' \"\$b\" | \$grepbin -q needle; then :; fi"                           # grepq-fixture (#1372)
)
for _spec in "${READER_SPELLINGS[@]}"; do
    IFS='|' read -r _lbl _wantline _body <<<"$_spec"
    _f="$TMP/monitor/watcher/spelling-$_lbl.sh"
    { printf '#!/usr/bin/env bash\nset -uo pipefail\n'; printf '%b\n' "$_body"; } > "$_f"
    mapfile -t _sp < <( _scan_root "$TMP" || true )
    if (( ${#_sp[@]} == 1 )) && [[ "${_sp[0]}" == *"spelling-$_lbl.sh:$_wantline:"* ]]; then
        ok "reader spelling \`$_lbl\` caught at the expected file and line — enumerated in COVERAGE BOUNDARY, asserted here"
    else
        bad "reader spelling/$_lbl" "expected exactly 1 hit in spelling-$_lbl.sh line $_wantline, got ${#_sp[@]}:
${_sp[*]:-<none>}
COVERAGE BOUNDARY claims this spelling. It carries the hazard (measured rc=141),
so a miss here is the boundary promising coverage the predicate does not deliver
— your-org/nexus-code#1029 exactly, reintroduced."
    fi
    rm -f "$_f"
done

# TRAILING-PIPE negative control, and it is the one that earns its keep. The
# split pass pairs a line ending in a pipe with the next line's reader. A
# `||`-joined pair of HERESTRING greps split across lines has the same
# silhouette — line N ends in `|`-ish, line N+1 opens with `grep -q` — and is
# the prescribed SAFE form. `_PIPE_EOL_RE` requires exactly ONE trailing pipe,
# which is what tells them apart. Planted so a future edit that relaxes it to
# `\|+` reddens here rather than flagging the fix this file prescribes.
cat > "$TMP/monitor/watcher/split-safe.sh" <<'SPLITSAFE'
#!/usr/bin/env bash
set -uo pipefail
grep -qF -- "$a" <<<"$x" ||
    grep -qF -- "$b" <<<"$y"
printf '%s' "$c" |
    wc -l
SPLITSAFE
mapfile -t _splitsafe < <( _scan_root "$TMP" || true )
if (( ${#_splitsafe[@]} == 0 )); then
    ok "the \`||\`-joined herestring pair SPLIT ACROSS LINES is not flagged, and neither is a trailing pipe into a NON-grep reader"
else
    bad "split control/false positive" "the trailing-pipe pass flagged a safe form: ${_splitsafe[*]}
A line ending in \`||\` is a boolean continuation, not a pipe; a trailing pipe into
\`wc\` is not an early-exiting reader. Flagging either trains people to ignore the guard."
fi
rm -f "$TMP/monitor/watcher/split-safe.sh"

# EXTENSIONLESS control — planted AT path monitor/ng, the exact file that was
# invisible (your-org/nexus-code#622 skeptic asked for the negative control to
# run against the file that hid, not a generic stand-in). It is extensionless
# with a bash shebang and carries the idiom; the CONTENT-based scan must catch
# it at monitor/ng. Under the old `--include='*.sh'` glob this assertion was
# structurally impossible — the file it names could never appear in the scan —
# which is precisely why it is the arm that demonstrates the fix. The real
# monitor/ng is proven clean by case 2 and in-scope by the coverage floor above;
# here we prove a violation IN it would be caught.
mkdir -p "$TMP/monitor"
cat > "$TMP/monitor/ng" <<'NGPLANT'
#!/usr/bin/env bash
set -uo pipefail
if tmux list-windows -F '#W' 2>/dev/null | grep -qxF "$win"; then echo open; fi  # grepq-fixture
NGPLANT
mapfile -t extless < <( _scan_root "$TMP" || true )
if (( ${#extless[@]} == 1 )) && [[ "${extless[0]}" == *"monitor/ng:3:"* ]]; then
    ok "planted violation AT extensionless monitor/ng caught by content — the #622 blind spot, closed"
else
    bad "monitor/ng control" "expected exactly the monitor/ng line-3 hit, got ${#extless[@]}:
${extless[*]:-<none>}
An extensionless shell script (monitor/ng) is invisible to an --include='*.sh'
scan — this is how four live sites, incl the dominant tmux-into-grep-q window shape,
survived until the #622 skeptic. The scan must enumerate by shebang, not name."
fi
rm -f "$TMP/monitor/ng"

# The converted form must NOT trip the lint (else it would be unsatisfiable),
# and neither may a `||`-joined pair of herestring greps — the false positive a
# naive `\| *grep` would raise, now excluded by the leading `(^|[^|])`.
cat > "$TMP/monitor/watcher/converted.sh" <<'CONV'
#!/usr/bin/env bash
set -uo pipefail
if grep -q 'needle' <<<"$body"; then echo hit; fi
if grep -qE 'needle' <<<"$body"; then echo hit; fi
grep -qF -- "$a" <<<"$x" || grep -qF -- "$b" <<<"$y"
CONV
mapfile -t after < <( _scan_root "$TMP" || true )
if (( ${#after[@]} == 0 )); then
    ok "the prescribed replacement (and a \`||\`-joined herestring pair) does not trip the lint"
else
    bad "control/fix" "the herestring/\`||\` form is flagged: ${after[*]}"
fi

# ===========================================================================
# your-org/nexus-code#1347 — the first-line probe over an UNFILTERED corpus.
# TWO-SIDED, because this is a POPULATION predicate and the dominant defect
# here is a silently SMALLER population, not a louder one.
# ===========================================================================
_n47=$(mktemp -d) || _n47=''
if [[ -n "$_n47" ]]; then
    # A binary whose FIRST LINE carries a NUL. `$( … )` cannot hold a NUL, so
    # the pre-#1347 form warned `ignored null byte in input` and yielded a
    # mangled value; `IFS= read -r -n 200` does neither. The `.pyc` that sits
    # under monitor/ on a working tree does NOT trigger it (its first line is
    # `3\r\r\n`), which is exactly why this control is PLANTED rather than
    # left to whatever binary happens to be present.
    printf '\x7fELF\x02\x01\x00\x00\x00\x00\x00\x00binary\n' > "$_n47/bin.dat"
    _w47=$( { IFS= read -r -n 200 _l47 < "$_n47/bin.dat" 2>/dev/null || _l47=''; } 2>&1 )
    if [[ -z "$_w47" ]]; then
        ok "#1347: a planted binary first-line read emits NO warning"
    else
        bad "#1347: a planted binary first-line read emits NO warning" "got: $_w47"
    fi

    # The OTHER direction, and the one that matters more: a real shell file
    # with an unusual first line must STILL classify as shell. An over-tight
    # read is a population that shrinks in silence.
    _miss47=0
    for _sheb47 in '#!/usr/bin/env  zsh' '#!/bin/sh' '#!/usr/bin/env bash' '#!/bin/bash -eu'; do
        printf '%s\nexit 0\n' "$_sheb47" > "$_n47/odd.sh"
        IFS= read -r -n 200 _l47 < "$_n47/odd.sh" 2>/dev/null || _l47=''
        grep -qE '^#!.*(bash|zsh|/sh$|/sh |env (ba|z)?sh)' <<<"$_l47" \
            || { _miss47=1; _bad47="$_sheb47"; }
    done
    if (( _miss47 == 0 )); then
        ok "#1347: four unusual-but-real shebangs still classify as shell"
    else
        bad "#1347: four unusual-but-real shebangs still classify as shell" "missed: ${_bad47:-?}"
    fi
    rm -rf "$_n47"
else
    bad "#1347 controls" "mktemp failed — the controls did NOT run"
fi

# ===========================================================================
echo
if (( FAIL > 0 )); then
    printf '%d passed, %d FAILED\n' "$PASS" "$FAIL"
    exit 1
fi
printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
exit 0
