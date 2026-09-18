#!/usr/bin/env bash
# early-exit-readers.sh — enumerate every EARLY-EXIT READER site in this repo
# on one DECLARED axis, so the boundary is checkable rather than asserted
# (your-org/nexus-code#682).
#
# Usage:  bash monitor/watcher/early-exit-readers.sh [--sites] [<repo-root>]
#   default   one row per (file, kind): `<file>\t<kind>\t<scope>\t<count>`
#   --sites   one row per site:         `<file>:<line>\t<kind>\t<scope>`
#
# ---------------------------------------------------------------------------
# WHY A CLASSIFIER AND NOT A CONVERSION
#
# `#622` fixed one reader — `| grep -q` — and gave it a lint. `#682` is about
# the OTHERS: `head`, `grep -m`, `sed …q`, `awk …exit`. The raw grep counts
# that motivated it (`head` 197, `awk` 143, `sed -n` 54, `grep -m` 1) are NOT
# a defect count, and converting on them would churn hundreds of safe sites
# and spend the review attention that catches the real ones.
#
# The distinction that collapses the number: `awk` and `sed` **drain their
# input** unless they carry an early `exit` / `q`. A `| sed -n 's/x/y/p'` reads
# to EOF and can never SIGPIPE its writer. So the population is not "uses awk"
# — it is "uses a reader that can close the pipe early".
#
# ---------------------------------------------------------------------------
# THE AXIS, STATED SO IT CAN BE DISAGREED WITH
#
#   1. FILES — git-tracked, under `monitor/`, and shell: decided by
#      `monitor/shell-files.sh`'s `shf_is_shell`, which is a `*.sh`-family name,
#      OR a `#!` line naming a shell, OR a shell startup-file name.
#
#      This classifier ALREADY got the shebang arm right — it is where the
#      correct pattern existed in-tree, and `#792`'s table listing it alongside
#      the two blind kill guards was wrong about it (see that issue's thread).
#      What it did not have was arm 3, so the four live zsh startup files under
#      `monitor/shellenv/` were outside its axis; and its predicate was its own
#      third implementation of a question that now has one. Sharing the
#      predicate is the point of `#792` even where the local answer happened to
#      be right — `#775` is what happens when two implementations of one notion
#      are left to drift.
#
#      The ENUMERATION SOURCE stays `git ls-files`, deliberately, and is not
#      shared: this classifier's axis says *git-tracked*, and the manifest it
#      feeds must not move because somebody left a scratch file in the tree.
#      Only the per-file PREDICATE is shared. That split is the boundary
#      between a legitimate per-consumer choice and the duplicated logic that
#      caused the defect.
#   2. PIPEFAIL, **including by inheritance** — the file must set `pipefail`
#      itself OR be sourced (transitively) by one that does. Without pipefail a
#      reader's early exit cannot become the pipeline's status, so the hazard
#      does not exist; but a SOURCED library runs inside the sourcer's shell
#      options, so it inherits the hazard without carrying the string. The
#      self-only form of this filter was a blind spot, not a boundary — see
#      `_pf_build_axis` below.
#   3. READER — the right-hand side of a `|` is one of:
#        `head`      — always exits before EOF once its count is met
#        `grep -m N` — likewise (`-q` is EXCLUDED; `#622` already lints it,
#                      and double-covering would double-report every site)
#        `sed …q/Q`  — only WITH a quit command; a bare `sed -n …p` drains
#        `awk …exit` — only WITH an `exit`; a bare `awk` drains
#   4. LINES — comments excluded; `\`-continuations joined first, because a
#      producer split from its pipe by a continuation is exactly how two live
#      instances survived `#622`'s lint twice (see test-sigpipe-assertion-lint).
#
#   5. SCOPE — AN EXECUTED COMMAND STRING IS ITS OWN PIPEFAIL SCOPE
#      (your-org/nexus-code#1130). This classifier used to have no answer here
#      at all, and the omission was not neutral: it read a `set -o pipefail`
#      inside a QUOTED DATA STRING as though the FILE had set the option, and
#      counted `| head` sites inside strings as though the file's shell ran
#      them. One phantom row was LIVE in the checked manifest at `7c4ddbb`
#      (`test-service-health-selfmatch.sh`, which sets only `set -u` and has
#      zero sourcers). The decision, now made rather than defaulted:
#
#        * A string handed to a runner is evaluated in a DIFFERENT shell. Its
#          `set -o pipefail` says nothing about THIS file's options, so it does
#          NOT put the file on the axis.
#        * Symmetrically, a reader inside that SAME string genuinely runs under
#          whatever that string enabled. So a `| head` whose PIPE is quoted is
#          on the axis iff the enclosing string itself enables pipefail.
#
#      This is why `test-service-health-selfmatch.sh:156`
#      (`"set -o pipefail; pgrep -f $M | head -1"`) IS a site while `:152`
#      (`"false | head -1"`) is not — the file's own comment at `:159` says the
#      two strings are health-check DATA, and the distinction between them is
#      the scoping rule, not a spelling. `#1127`'s command-position anchor
#      removed the live row for a reason that does not generalise: it rejected
#      that string only because the string BEGAN with `set`. Spelled
#      `"foo; set -o pipefail"` the phantom row would still be here.
#
# NOT ON THE AXIS, and therefore NOT claimed about: shell outside `monitor/`;
# untracked files; readers reached through `xargs`, `$(…)` nesting the pipe
# inside another command's arguments, or a variable holding the reader name;
# a file whose pipefail arrives from a sourcer OUTSIDE `monitor/`, or via a
# dynamically-constructed `source` path (the inheritance closure matches source
# lines by basename, so a computed name is invisible); a string whose pipefail
# arrives from the shell that EVALUATES it rather than from its own text (the
# scope rule above is decided per string, one level, with no dataflow); and the
# question of whether any given site is a live BUG. This enumerates the
# population a reviewer must look at. It does not adjudicate it.
#
# ---------------------------------------------------------------------------
# WHY (file, kind, COUNT) AND NOT (file, LINE)
#
# A manifest keyed on line numbers goes red whenever anything above a site is
# edited. A boundary that cries wolf on unrelated edits gets regenerated
# reflexively, and a manifest that is regenerated without being read protects
# nothing — the same failure mode `#622`'s lint prose warns about one level up.
# Keyed on counts, ordinary edits are silent and only a NEW site (or a removed
# one) moves the number.
set -uo pipefail

_mode=rows
_root=""
for a in "$@"; do
    case "$a" in
        --sites) _mode=sites ;;
        # your-org/nexus-code#803 — the file set this scan reads, one path per
        # line, for monitor/guards-for-diff.sh. Not a classification: see
        # _eer_axis_files below.
        --population) _mode=population ;;
        *)       _root="$a" ;;
    esac
done
# The shared shell-file predicate — see THE AXIS, item 1. Resolved against THIS
# SCRIPT's location, never against `$_root`: the suite runs this classifier
# against synthetic fixture roots, and a root-relative path would fail to source
# there, exit 1, and hand every positive control an empty classification — a
# silent zero inside the very controls that exist to prove the classifier fires.
_shf_lib=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/shell-files.sh
[[ -r "$_shf_lib" ]] || {
    echo "early-exit-readers: missing $_shf_lib" >&2; exit 1; }
# shellcheck source=/dev/null
. "$_shf_lib"

if [[ -z "$_root" ]]; then
    _root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fi
cd "$_root" || exit 1

# The scope split is reported, not filtered: `#682`'s useful subset is the
# PRODUCTION one (a spuriously non-zero pipeline silently takes the wrong
# branch), while a test-suite site merely goes red. Both belong in the
# manifest; only one is worth a reviewer's time first.
_scope() {
    case "$1" in
        */test-*|*/_test_helpers.sh|*/test/*) printf 'test' ;;
        *) printf 'prod' ;;
    esac
}

# PIPEFAIL, INCLUDING BY INHERITANCE (your-org/nexus-code#682 skeptic F5).
#
# The first version tested `set -o pipefail` in the file itself. That silently
# excluded every SOURCED LIBRARY: `monitor/watcher/_lib.sh` sets no pipefail of
# its own, is sourced 14 times by `main.sh` which does, and carries live on-axis
# sites at `:1226` and `:1498` — yet had ZERO manifest rows. Appending a real
# `sed -n '1p;q'` to it left the classifier's total unchanged at 192, which is
# the definition of a blind spot rather than a boundary.
#
# This is not a novel discovery, which is the damning part: the repo already
# names it at `_lib.sh:2787-2793` — "every library that INHERITS it … was
# invisible to that audit". `#682` inherited `#622`'s filter and reproduced
# `#622`'s blind spot, and the axis's `NOT ON THE AXIS` disclosure did not
# mention it, so the gap was not even declared.
#
# A sourced file runs inside the sourcer's shell options, so it is on the axis
# whenever ANY file that sources it is. Computed as a FIXPOINT so a chain
# (`a.sh` sets pipefail → sources `_b.sh` → sources `_c.sh`) is covered; a
# single-level check would leave the same class of hole one link further out.
# THE PIPEFAIL PREDICATE, DEFINED ONCE (your-org/nexus-code#1130). It is used
# twice — for the FILE axis below and, through `-v PF=`, for the per-STRING
# scope in the site scan. Two copies of one notion is `#775`/`#842`'s defect,
# and here the copies would have to agree across two regex dialects to stay
# honest. `[[:space:]]` is valid in both POSIX ERE consumers (`grep -E`, awk).
_PF_RE='(^|[;&|(){}[:space:]])set([[:space:]]+[+-][a-zA-Z]+)*[[:space:]]+-[a-zA-Z]*o[[:space:]]+("|'"'"')?pipefail|(^|[;&|(){}[:space:]])set([[:space:]]+[+-][a-zA-Z]+)*[[:space:]]+-o[[:space:]]+([a-z]+[[:space:]]+-o[[:space:]]+)*("|'"'"')?pipefail|(^|[;&|(){}[:space:]])setopt([[:space:]]+[A-Za-z_]+)*[[:space:]]+[Pp][Ii][Pp][Ee]_?[Ff][Aa][Ii][Ll]|(^|[;&|(){}[:space:]])shopt([[:space:]]+-[a-zA-Z]+)*[[:space:]]+-[a-zA-Z]*o[a-zA-Z]*([[:space:]]+-[a-zA-Z]+)*[[:space:]]+("|'"'"')?pipefail'

# The ONE shell-quote state machine (your-org/nexus-code#842). Resolved against
# THIS SCRIPT's location for the same reason `_shf_lib` is: the suite runs this
# classifier against synthetic fixture roots.
_EER_QAWK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_shell_quotes.awk
[[ -r "$_EER_QAWK" ]] || {
    echo "early-exit-readers: missing $_EER_QAWK" >&2; exit 1; }

declare -A _PF_AXIS=()      # files on the axis (own pipefail, or inherited)
# The comment-stripped CODE of every file, memoised. `shf_strip_comments` is an
# awk process per file and BOTH passes need it — the axis predicate here and the
# site scan below. Recomputing it there cost ~2x the classifier's whole runtime,
# and this file is invoked six times by its own suite; a classifier drifting
# toward the per-test ceiling becomes an intermittent red (#655).
declare -A _PF_CODE=()
declare -A _PF_BYBASE=()    # basename -> newline-list of tracked paths

# Built from ONE `git ls-files` and resolved in memory. The first version
# re-ran `git ls-files | grep` per source line per axis file — O(n*m)
# subprocesses, 26 s per invocation, and this classifier is invoked six times
# by its own suite. That is not merely slow: a suite that drifts toward the
# per-test ceiling becomes an INTERMITTENT red, which is the exact class
# (#655) this round spent a component on. Fixed before it could land.
_pf_build_axis() {
    local f base
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        base="${f##*/}"
        _PF_BYBASE["$base"]="${_PF_BYBASE[$base]:-}$f"$'\n'
        # THE AXIS IS DECIDED ON CODE, NOT ON TEXT (your-org/nexus-code#1106).
        #
        # This was a bare `grep` over the whole file, and it was wrong in BOTH
        # directions.
        #
        # FALSE POSITIVES: a COMMENT naming the option enrolled the file — and
        # the most natural comment there is, is the one explaining why a file
        # deliberately does NOT set it. Measured at `7c4ddbb`, SIX files match
        # the old predicate only inside comments (`_install-lib.sh`,
        # `_merge_ref_base.sh`, `_remote_lib.sh`, `hooks/pending-tool-record.sh`,
        # `watcher/_orphan_async.sh`, `watcher/_test_helpers.sh`). Note this is
        # NOT the same six `#1106` listed: `watcher/_lib.sh` left the set when
        # its comment was reworded, and `_orphan_async.sh` joined it. A list
        # decays; the mechanism does not.
        #
        # FALSE NEGATIVES: the old alternation used a literal SPACE (` +`), so a
        # TAB-separated `set<TAB>-o<TAB>pipefail` was invisible; it required
        # `pipefail` to sit immediately after the first `-o`, so
        # `set -o errexit -o pipefail` was invisible; and it did not allow the
        # operand to be quoted, so `set -o "pipefail"` was invisible. All three
        # were verified BY EXECUTION to turn the option ON
        # (`[[ -o pipefail ]]` -> ON) and to be missed by the old regex.
        #
        # BOTH DIRECTIONS ARE LATENT AT `7c4ddbb`, stated so nobody over-reads
        # this: all six false positives are already on the axis BY INHERITANCE,
        # and NO file in the tree uses any of the three missed spellings — so
        # the classifier emits an identical 115 rows either way. It is a latent
        # defect in a CHECKED boundary manifest, not a live wrong row.
        #
        # The stripped text goes in a VARIABLE and is matched with a herestring.
        # It must NOT be `shf_strip_comments "$f" | grep -qE …`: this file runs
        # under `pipefail`, `grep -q` exits early, the producer takes SIGPIPE,
        # and the pipeline returns 141 — which is the early-exit-reader defect
        # this classifier exists to find, rebuilt inside it. `#1106` records
        # that exact mistake being made while measuring the bug.
        _pf_code=$(shf_strip_comments "$f") || {
            printf 'early-exit-readers: cannot read %s as code — refusing to\n' "$f" >&2
            printf '  guess its pipefail state.\n' >&2
            exit 2
        }
        # AND THE AXIS IS DECIDED ON CODE, NOT ON A STRING CONTAINING CODE
        # (your-org/nexus-code#1130). `shf_strip_comments` removes comments; it
        # does not remove QUOTED DATA, and this predicate used to enrol a file
        # on the strength of an option named inside one. The scoping decision,
        # stated because the `NOT ON THE AXIS` block never made it:
        #
        #   AN EXECUTED COMMAND STRING IS ITS OWN PIPEFAIL SCOPE.
        #
        # A string handed to a runner is evaluated in a DIFFERENT shell, so a
        # `set -o pipefail` inside it says nothing about the options of THIS
        # file — and, symmetrically, a `| head` inside the SAME string really
        # does run under it. The file-level axis therefore requires the
        # KEYWORD to be unquoted, and the per-site scan below gives each string
        # its own scope. `#1127`'s command-position anchor rejected the live
        # instance only because that string BEGAN with `set`; spelled
        # `"foo; set -o pipefail"` the phantom row would still be here.
        #
        # THE KEYWORD, NOT THE WHOLE MATCH — and this is the correction that
        # matters. Deleting quoted spans and matching what is left is the
        # obvious repair and is WRONG in the other direction: `set -o "pipefail"`
        # is real code with a QUOTED OPERAND, verified by execution to turn the
        # option ON, and stripping the span deletes the operand. So the mask
        # decides only where the `set`/`setopt`/`shopt` WORD is; from there the
        # line is matched with quote characters blanked, which lets a quoted
        # operand match and cannot resurrect a keyword that was itself quoted.
        # PRE-FILTER, and it is exact rather than a heuristic: the mask scan below
        # can only ever REJECT a textual match (by finding the keyword quoted);
        # it can never create one. So a file whose stripped code does not match
        # the predicate AT ALL cannot be on the axis, and skipping the awk for it
        # changes no answer. Measured: it halves this function's awk invocations.
        if ! grep -qE "$_PF_RE" <<<"$_pf_code"; then
            _PF_CODE["$f"]=$_pf_code
            continue
        fi
        _pf_hit=$(awk -v PF="$_PF_RE" "$(cat "$_EER_QAWK")"'
            { m = quote_mask($0, carry); carry = QM_END; L = length($0)
              for (i = 1; i <= L; i++) {
                  if (substr(m, i, 1) == "1") continue
                  if (i > 1 && substr($0, i - 1, 1) ~ /[A-Za-z0-9_]/) continue
                  # `set`, `setopt` and `shopt` — the three keyword prefixes
                  # the predicate can start at. Three characters is enough to
                  # discriminate and keeps the scan cheap.
                  w = substr($0, i, 3)
                  if (w != "set" && w != "sho") continue
                  tail = substr($0, i); gsub(/["\047]/, " ", tail)
                  if (("; " tail) ~ PF) { print "1"; exit }
              }
            }' <<<"$_pf_code") || {
            printf 'early-exit-readers: cannot mask quotes in %s — refusing to\n' "$f" >&2
            printf '  guess its pipefail state.\n' >&2
            exit 2
        }
        _PF_CODE["$f"]=$_pf_code
        if [[ "$_pf_hit" == 1 ]]; then
            _PF_AXIS["$f"]=1
        fi
    done < <(git ls-files -- 'monitor/**' 2>/dev/null)

    # Fixpoint over source edges: a sourced file runs inside the sourcer's
    # shell options, so it is on the axis whenever any sourcer is. Iterated
    # rather than single-level so a chain (a.sh -> _b.sh -> _c.sh) is covered.
    local changed=1 g cand
    while (( changed )); do
        changed=0
        for g in "${!_PF_AXIS[@]}"; do
            [[ -f "$g" ]] || continue
            while IFS= read -r base; do
                [[ -n "$base" ]] || continue
                while IFS= read -r cand; do
                    [[ -n "$cand" ]] || continue
                    if [[ -z "${_PF_AXIS[$cand]:-}" ]]; then
                        _PF_AXIS["$cand"]=1; changed=1
                    fi
                done <<< "${_PF_BYBASE[$base]:-}"
            done < <(grep -hE '^[[:space:]]*(\.|source)[[:space:]]' "$g" 2>/dev/null \
                     | grep -oE '[A-Za-z_][A-Za-z0-9._-]*\.sh' | sort -u || true)
        done
    done
}
# NOT CALLED HERE. `--population` does not need the axis and used to pay for it
# anyway: measured, `--population` was 49 s of which ~48 s was this function,
# and `monitor/guards-for-diff.sh` calls it once per declaring guard. That cost
# is what pushed `test-guards-for-diff.sh` from 420 s to over its 600 s ceiling
# — a suite drifting toward the per-test ceiling becomes an INTERMITTENT red,
# which is `#655`'s class and worse than the slowness. The call now sits below
# the `--population` early exit, which is where that block's own comment already
# says the work stops.

_on_pipefail_axis() { [[ -n "${_PF_AXIS[$1]:-}" ]]; }

# THE AXIS FILE SET, as a function, so `--population` (your-org/nexus-code#803)
# reports the set this classifier actually walks rather than a second copy of
# the same enumeration. A copy is how a reverse index comes to state, with
# total confidence, that a guard does not read a file it does read.
_eer_axis_files() {
    git ls-files -- 'monitor/**' 2>/dev/null | while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        # The shared predicate (your-org/nexus-code#792). This replaces a local
        # `*.sh` + `grep -qE '^#!.*(bash|sh|zsh)'` pair that was RIGHT about the
        # shebang arm and wrong about two smaller things — it had no startup-file
        # arm, so `shellenv/.zshenv` and its three siblings were off the axis; and
        # its regex matched the substring `sh` anywhere on the shebang line, so
        # `#!/usr/bin/env pwsh` would have classified as a shell.
        shf_is_shell "$f" || continue
        printf '%s\n' "$f"
    done
}

# `--population` stops HERE, before any classification: the caller asked which
# files this scan reads, not what it found in them. The `_on_pipefail_axis`
# filter below is deliberately NOT applied — a file off the pipefail axis is
# still read, and an edit that puts it ON the axis is exactly the change a
# worker needs to be told about.
if [[ "$_mode" == population ]]; then
    _eer_axis_files
    exit 0
fi

_pf_build_axis

_eer_axis_files | while IFS= read -r f; do
    # NO LONGER `_on_pipefail_axis "$f" || continue` (your-org/nexus-code#1130).
    # A file OFF the file-level axis can still carry an on-axis site, because an
    # EXECUTED COMMAND STRING IS ITS OWN PIPEFAIL SCOPE: the string enables the
    # option in the shell that evaluates it, and a reader inside that same
    # string really does run under it. `test-service-health-selfmatch.sh` sets
    # only `set -u` and has zero sourcers, and its `:156`
    # `"set -o pipefail; pgrep -f $M | head -1"` is exactly such a site — while
    # its `:152` `"false | head -1"` is not, and must stay out. The file gate is
    # therefore passed INTO the scan as FILEAXIS rather than applied before it.
    # COMMENT-STRIPPED TEXT, and the mask CARRIED across the newline. Both
    # halves are needed and each defeats the other'"'"'s failure mode. Carrying a
    # per-line mask over RAW text lets an apostrophe in comment prose mark every
    # following line as quoted; NOT carrying it re-opens a quote at the start of
    # any line that continues a multi-line string, which lost a real site —
    # `_github.sh:374`, the `| head -n1` after a six-line single-quoted `jq`
    # program. Stripping comments first removes the poisoning text; carrying
    # then models the string that genuinely spans lines. One line per input
    # line, so line NUMBERS are unchanged.
    _eer_code=${_PF_CODE[$f]-}
    if [[ -z "$_eer_code" ]]; then
        _eer_code=$(shf_strip_comments "$f") || {
            printf 'early-exit-readers: cannot read %s as code — refusing to guess\n' "$f" >&2
            exit 2
        }
    fi
    awk -v F="$f" -v SCOPE="$(_scope "$f")" -v PF="$_PF_RE" \
        -v FILEAXIS="$(_on_pipefail_axis "$f" && echo 1 || echo 0)" \
        "$(cat "$_EER_QAWK")"'
      function emit(r, ln,   kind) {
          sub(/^[ \t]+/, "", r)
          kind = ""
          if (r ~ /^head( |$)/)                                              kind = "head"
          else if (r ~ /^grep/ && r ~ /(-[a-zA-Z]*m[ =]?[0-9]|--max-count)/)  kind = "grep-m"
          else if (r ~ /^sed/  && r ~ /[;{ \t'\''"][0-9$]*[ \t]*[qQ][ \t]*([;}'\''"]|$)/) kind = "sed-q"
          else if (r ~ /^awk/  && r ~ /(^|[^a-zA-Z_])exit([^a-zA-Z_]|$)/)     kind = "awk-exit"
          if (kind != "") printf "%s\t%d\t%s\t%s\n", F, ln, kind, SCOPE
      }
      { line = $0; sub(/^[ \t]+/, "", line) }
      # Join backslash-continuations BEFORE matching. A producer separated
      # from its pipe by a continuation is how two live instances survived
      # the #622 lint on two separate occasions.
      /\\[ \t]*$/ { if (accln == 0) accln = NR; acc = acc substr(line, 1, length(line) - 1) " "; next }
      {
          if (acc != "") { line = acc line; ln = accln; acc = ""; accln = 0 } else { ln = NR }
      }
      line ~ /^#/ { next }
      {
          # THE QUESTION IS WHETHER THE PIPE IS QUOTED, NOT WHETHER THE READER
          # IS (your-org/nexus-code#1130). Deleting quoted spans and scanning
          # what is left is the obvious repair and is measurably wrong: the
          # reader KIND is decided by the reader'"'"'s ARGUMENTS, and those are
          # normally quoted — `| awk '"'"'NF>=2 { … exit }'"'"'` becomes `| awk ` and
          # stops being an `awk-exit` site. Measured on this tree, that repair
          # dropped 28 of 114 rows, nearly all of them real code. What decides
          # SCOPE is the `|` itself: an UNQUOTED pipe runs in this file'"'"'s shell,
          # a QUOTED one runs in whatever shell evaluates the string.
          #
          # TWO MASKS, AND "QUOTED" IS BELIEVED ONLY WHEN BOTH AGREE. Each
          # single reading loses REAL sites, in opposite places, and the losses
          # were measured on this tree rather than reasoned about:
          #
          #   PER-LINE      re-opens a quote at the start of any line that
          #                 CONTINUES a multi-line string. Lost `_github.sh:374`
          #                 — the `| head -n1` after a six-line single-quoted
          #                 `jq` program. 1 real site.
          #   CARRIED       accumulates desync from the quoting forms
          #                 `_shell_quotes.awk` states it does not model ($'…'
          #                 ANSI-C quoting, escapes outside a string), and the
          #                 error persists to end of file. Lost 8 real sites,
          #                 including `monitor/ng:6354` and
          #                 `spawn-worker.sh:2524`, all of them plain
          #                 `x=$(… | head -1)` assignments.
          #
          # A LOST site is a silent under-count of a defect population; a
          # spurious one is a manifest row a reviewer dismisses. So the
          # disjunction is deliberate and its direction is stated: a pipe is
          # judged QUOTED only if BOTH readings say so, and a disagreement is
          # resolved toward CODE. This classifier enumerates the population a
          # reviewer must look at; it does not adjudicate it.
          mline = quote_mask(line); mcarry = quote_mask(line, carry); carry = QM_END
          L = length(line); m = ""
          for (i = 1; i <= L; i++)
              m = m ((substr(mline, i, 1) == "0" || substr(mcarry, i, 1) == "0") ? "0" : "1")
          delete spantext; delete spanof; nspan = 0
          i = 1
          while (i <= L) {
              if (substr(m, i, 1) == "1") {
                  nspan++; st = i
                  while (i <= L && substr(m, i, 1) == "1") { spanof[i] = nspan; i++ }
                  spantext[nspan] = substr(line, st, i - st)
              } else { spanof[i] = 0; i++ }
          }
          start = 1; pq = -1
          for (i = 1; i <= L + 1; i++) {
              if (i <= L && substr(line, i, 1) != "|") continue
              if (pq >= 0) {
                  # A segment that FOLLOWS a pipe. On the axis iff its pipe was
                  # unquoted and the FILE is, or its pipe was quoted and THAT
                  # STRING enables pipefail.
                  # The span RUN includes its delimiting quote characters, and
                  # `"set -o pipefail; …"` would not match a predicate anchored
                  # at a command position — the `"` is not a separator. Blank
                  # the quote characters for the test only; that is the same
                  # question with the delimiters removed, and it is how the one
                  # LIVE instance (`test-service-health-selfmatch.sh:156`) is
                  # recognised while `:152` (`"false | head -1"`, no pipefail
                  # anywhere in the string) stays out.
                  spanq = spantext[pq]; gsub(/["'"'"']/, " ", spanq)
                  onaxis = (pq == 0) ? (FILEAXIS == 1) : (spanq ~ PF)
                  if (onaxis) emit(substr(line, start, i - start), ln)
              }
              if (i > L) break
              pq = spanof[i]; start = i + 1
          }
      }
    ' <<< "$_eer_code"
done | if [[ "$_mode" == sites ]]; then
    # LC_ALL=C on every sort. Without it the output is LOCALE-DEPENDENT and the
    # manifest is only valid on the machine that generated it: `en_US.utf8`
    # collation ignores a leading `_`, so `monitor/_remote_lib.sh` sorts among
    # the `c`s, while byte-order puts it first. Same 91 rows, different ORDER —
    # the suite passed locally and failed in all four CI cells. A manifest is a
    # byte comparison; it must not encode the author's locale.
    awk -F'\t' '{ printf "%s:%s\t%s\t%s\n", $1, $2, $3, $4 }' | LC_ALL=C sort
else
    awk -F'\t' '{ key = $1 "\t" $3 "\t" $4; c[key]++ }
                END { for (k in c) printf "%s\t%d\n", k, c[k] }' | LC_ALL=C sort
fi
