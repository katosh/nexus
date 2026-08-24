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
# COVERAGE BOUNDARY. This lint covers ANY producer piped into `grep` with a
# `q` flag — `<anything> | grep -<…q…>` — under monitor/, whether the pipe sits
# on one line or is split across a `\`-continuation. It is PRODUCER-AGNOSTIC by
# design: the hazard is the READER, not the writer. `grep -q` exits on first
# match without draining, and `pipefail` promotes the writer's EPIPE to the
# pipeline's status no matter what wrote the bytes (your-org/nexus-code#622).
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
# Two shapes are deliberately NOT flagged because they carry no pipe into grep:
# the safe replacement `grep -q … <<<"…"`, and a `||`-joined herestring
# (`… <<<"…" || grep -qF … <<<"…"`) whose `||` a naive `\| *grep` misreads as a
# pipe. Case 3 asserts both stay green, and plants both a `\`-continuation and
# an extensionless shebang script to prove the two non-regex proxies are gone.
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
# WHAT IS STILL NOT COVERED, AND WHY. Only a DIFFERENT early-exit reader:
# `cmd | head`, `cmd | grep -m1`. They exit before draining exactly as
# `grep -q` does and carry the identical hazard, but they are a wider class the
# repo has not swept — documented-unlinted, not converted. This is a READER
# boundary (which matcher), not a producer boundary: do not let a future edit
# narrow it back onto the writer. As of #622 every `<producer> | grep -q` under
# monitor/ — production and test, single-line and `\`-continuation — is
# converted, and (case 2b) no non-shell doc under monitor/ PRESCRIBES the piped
# form. The `| grep -q` text that remains under monitor/ is INTENTIONAL
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
# PRODUCER-AGNOSTIC: `<preceding char that is NOT a pipe>| … grep -<…q…>`. The
# leading `(^|[^|])` matches a real single pipe while refusing `||` (a herestring
# OR, not a pipe into grep); it needs no producer token on the line, so a
# `\`-continuation `… \` ⏎ `| grep -q` is caught on its `| grep` line. `q` is
# required (early-exit), so `grep -c` and a `-q`-less `grep` are correctly out,
# and so is the safe `grep -q … <<<"…"` (no pipe). See COVERAGE BOUNDARY.
LINT_RE='(^|[^|])\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q'
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
_shell_files() {   # emits monitor/… paths relative to CWD
    { find monitor -type f \( -name '*.sh' -o -name '*.zsh' -o -name '*.bash' \
          -o "${_SOURCED_SHELL[@]}" \);
      find monitor -type f ! -name '*.sh' ! -name '*.zsh' ! -name '*.bash' -print0 \
        | while IFS= read -r -d '' _f; do
            # The mechanism obeys its own rule: the shebang test is the prescribed
            # herestring form, NOT `head … | grep -q`. That pipeline was the FOURTH
            # proxy in this lineage (pipefail-file → producer-name → file-glob → the
            # enforcement mechanism re-instantiating the banned class), hidden by a
            # blanket self-exemption. your-org/nexus-code#622 skeptic, round 2.
            grep -qE '^#!.*(bash|zsh|/sh$|/sh |env (ba|z)?sh)' \
              <<<"$(head -1 "$_f" 2>/dev/null)" && printf '%s\n' "$_f";
          done;
    } | sort -u
}
_scan_root() {   # $1 = tree whose monitor/ subtree to scan; grep the shell files
    ( cd "$1" 2>/dev/null || exit 0
      local -a _files; mapfile -t _files < <(_shell_files)
      (( ${#_files[@]} )) || exit 0
      grep -EHn "$LINT_RE" "${_files[@]}" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
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
    find monitor -type f | sort -u | while IFS= read -r _f; do
        grep -qxF "$_f" <<<"$_sh" && continue
        [[ "$_f" =~ $_NOT_SHELL_NOT_DOC ]] && continue
        printf '%s\n' "$_f"
    done
}
# NOTE: no comment-line filter here. In a doc, the snippet IS the payload —
# filtering comments would re-hide the exact site this case exists to catch.
_doc_scan() {
    ( cd "${1:-$REPO_ROOT}" 2>/dev/null || exit 0
      local -a _files; mapfile -t _files < <(_doc_files)
      (( ${#_files[@]} )) || exit 0
      grep -EHn "$LINT_RE" "${_files[@]}" 2>/dev/null )
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
    grep -qE '^#!.*(bash|zsh|/sh$|/sh |env (ba|z)?sh)' \
        <<<"$(head -1 "$REPO_ROOT/$_f" 2>/dev/null)" && _excluded_but_shell+=("$_f")
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
echo
if (( FAIL > 0 )); then
    printf '%d passed, %d FAILED\n' "$PASS" "$FAIL"
    exit 1
fi
printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
exit 0
