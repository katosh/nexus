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
# NOT ON THE AXIS, and therefore NOT claimed about: shell outside `monitor/`;
# untracked files; readers reached through `xargs`, `$(…)` nesting the pipe
# inside another command's arguments, or a variable holding the reader name;
# a file whose pipefail arrives from a sourcer OUTSIDE `monitor/`, or via a
# dynamically-constructed `source` path (the inheritance closure matches source
# lines by basename, so a computed name is invisible); and the question of
# whether any given site is a live BUG. This enumerates the population a
# reviewer must look at. It does not adjudicate it.
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
declare -A _PF_AXIS=()      # files on the axis (own pipefail, or inherited)
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
        if grep -qE 'set +-[a-zA-Z]*o +pipefail|set +-o +pipefail' "$f"; then
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
_pf_build_axis

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

_eer_axis_files | while IFS= read -r f; do
    _on_pipefail_axis "$f" || continue
    awk -v F="$f" -v SCOPE="$(_scope "$f")" '
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
          n = split(line, seg, /\|/)
          for (i = 2; i <= n; i++) {
              r = seg[i]; sub(/^[ \t]+/, "", r)
              kind = ""
              if (r ~ /^head( |$)/)                                              kind = "head"
              else if (r ~ /^grep/ && r ~ /(-[a-zA-Z]*m[ =]?[0-9]|--max-count)/)  kind = "grep-m"
              else if (r ~ /^sed/  && r ~ /[;{ \t'\''"][0-9$]*[ \t]*[qQ][ \t]*([;}'\''"]|$)/) kind = "sed-q"
              else if (r ~ /^awk/  && r ~ /(^|[^a-zA-Z_])exit([^a-zA-Z_]|$)/)     kind = "awk-exit"
              if (kind != "") printf "%s\t%d\t%s\t%s\n", F, ln, kind, SCOPE
          }
      }
    ' "$f"
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
