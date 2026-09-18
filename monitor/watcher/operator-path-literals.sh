#!/usr/bin/env bash
# operator-path-literals.sh — enumerate OPERATOR-SPECIFIC ABSOLUTE PATH literals
# in the docs and templates other operators install from
# (your-org/nexus-code#1275, #1174).
#
# ---------------------------------------------------------------------------
# THE DEFECT CLASS
# ---------------------------------------------------------------------------
#
# `nexus-code` is cloned by every operator. A file that ships ONE operator's
# absolute path and instructs the reader to install it hands this operator's
# layout to somebody else, and **the consequence is an absence**: the pasted
# line silently never arms anything, and the reader's evidence that it worked
# is that their shell started normally — which it would either way.
#
# Two instances in two weeks, both found by a person rather than by a check:
#   #1174  monitor/boot-recover.session-start-hook.json  (a settings template)
#   #1275  monitor/README.md                             (a ~/.zprofile snippet)
#
# `#1275` asked for exactly this ratchet, and named the trap in advance:
# **key on the SHAPE, never on this operator's literal path**, or the guard is
# green for every other operator by construction.
#
# ---------------------------------------------------------------------------
# APPLICABILITY, NOT CONFORMANCE (_guard_population.sh, rule 2)
# ---------------------------------------------------------------------------
#
# The population is "tracked `*.md` and `*.json`" — files a reader INSTALLS
# FROM. It is NOT "files that contain an operator path", which is a conformance
# predicate: it would make a file's membership depend on the very property
# under test.
#
# ---------------------------------------------------------------------------
# WHAT IS DELIBERATELY OUT OF POPULATION, AND WHY — these are reasoned
# exclusions, not an oversight, and each has a property the doc surface lacks
# ---------------------------------------------------------------------------
#
#   monitor/watcher/fixtures/*.ansi   CAPTURED terminal output. The literal is
#                                     a RECORDING of what a pane displayed;
#                                     rewriting it would falsify the fixture.
#   monitor/public-mirror/mapping.tsv Its PURPOSE is to contain the operator's
#                                     path — it is the redaction map that
#                                     strips it from the public mirror. A guard
#                                     that flagged it would be demanding the
#                                     removal of the mechanism that fixes the
#                                     class.
#   *.sh, monitor/ng                  Test data and code comments. The literal
#                                     is an INPUT to a transformation (the
#                                     project-slug encoding) or a worked
#                                     example inside a comment, never something
#                                     a reader installs.
#   assets/ (ROOT-anchored)           Wrap-up REPORTS, the same property as the
#                                     `.ansi` fixtures: a RECORD of what one
#                                     agent did on one host at one time.
#                                     Rewriting `/shared/…/user/<op>/` to
#                                     `<YOUR_NEXUS_ROOT>` inside a recording
#                                     would make it say something that did not
#                                     happen, and nobody installs from it. The
#                                     path is `.gitignore`d by design (it is the
#                                     asset-repo clone's mount point), so
#                                     anything TRACKED there was misrouted by
#                                     `upload-asset.sh` (your-org/nexus-code#1173,
#                                     fixed; #1457 is the red it caused when a
#                                     promotion back-merge carried four such
#                                     files onto `dev`). Whether those files
#                                     should be REMOVED is a separate question
#                                     — this exclusion answers only whether
#                                     they are a doc surface, and they are not.
#                                     Anchored at the repo root on purpose:
#                                     `monitor/assets/README.md` or
#                                     `docs/assets.md` would be doc surfaces
#                                     and stay IN population (the enforcing
#                                     suite plants both and requires them red).
#
# THE DIRECTION THIS PREDICATE ERRS IN, stated because a source-text predicate
# for an install-time property is an approximation and you should be able to
# say which way it is wrong: it UNDER-counts. A doc that instructs installation
# in a file extension not listed here is invisible to it, and so is an
# operator-specific path whose shape is not one of the three families below.
# It does not over-count: everything it flags really is an operator-shaped
# literal in a file a reader installs from.
#
# ---------------------------------------------------------------------------
# THE THREE SHAPE FAMILIES — the declared axis
# ---------------------------------------------------------------------------
#
#   fh-user     /shared/<tier>/<lab>/user/<operator>/…   the your-institution layout
#   home-user   /home/<user>/…                       excluding generic
#                                                    CI/container accounts
#   macos-user  /Users/<user>/…
#
# A path whose per-reader segment is already a VARIABLE — `/shared/<lab>/user/
# $USER/nexus`, `<YOUR_NEXUS_ROOT>/…` — does not match, because it is the
# correct general form. `docs/admin/your-org-addendum.md` demonstrates both in
# one file: `:155` writes `$USER` and is right; `:45` writes a literal and is
# recorded below with its reason.
#
# ---------------------------------------------------------------------------
# USAGE
#   bash monitor/watcher/operator-path-literals.sh              # rows
#   bash monitor/watcher/operator-path-literals.sh --detail     # rows + lines
#   bash monitor/watcher/operator-path-literals.sh --population # the protocol
#
# Enforced by: bash monitor/watcher/test-operator-path-literals-manifest.sh
#
# REGENERATING THE MANIFEST IS NOT A FIX. If the suite goes red, a doc or
# template gained an operator-specific literal. Decide which it is:
#   * a per-READER path (their nexus root, their dotfile, their home) — that is
#     the #1275 defect. Write the general form (`<YOUR_NEXUS_ROOT>`, `$USER`);
#     do not record it.
#   * a SHARED resource at a fixed location that every reader really does hit
#     literally — record it, with the reason, in the header below.
set -uo pipefail

_opl_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The tree SCANNED. Overridable so the enforcing suite can point the real,
# unmodified classifier at a planted fixture repo — a positive control has to
# drive the shipping code, not a copy of it, or it proves nothing about what
# ships. The LIBRARY path below is deliberately NOT derived from this: the
# guard-population protocol lives beside this script, never in the scanned tree.
REPO_ROOT="${OPL_REPO_ROOT:-$(cd "$_opl_dir/../.." && pwd)}"
_opl_lib_root=$(cd "$_opl_dir/.." && pwd)

# The three declared shape families, as one ERE. `-E` on purpose: in BRE a
# backslashed punctuation character can CREATE an operator rather than escape
# one (your-org/nexus-code#1158), and this pattern's job is to SELECT, so a
# dialect slip here silently changes the population.
_OPL_RE='/shared/[^/[:space:]]+/[^/[:space:]]+/user/[^/[:space:]$<]+/|/home/[a-z][a-z0-9_-]*/|/Users/[A-Za-z][A-Za-z0-9_.-]*/'
# Generic accounts that are NOT an operator identity — a CI runner or a
# container default is the same on every host, so it carries no layout.
_OPL_GENERIC='/home/(runner|ubuntu|user|root|node|vscode|codespace)/'

# _opl_population — the APPLICABILITY corpus. Tracked docs and templates.
# `:(glob)` because git's pathspec `*` crosses `/` without it
# (your-org/nexus-code#954); here both forms are wanted, so both are listed.
# `:(exclude)assets/` is a NON-glob pathspec, so it is a leading-directory
# match rooted at the repo top level: it removes `assets/**` and nothing whose
# path merely CONTAINS an `assets/` segment (see the out-of-population block).
# Measured at git 2.17.1, the oldest on this host, at e382e9fd: 92 -> 88
# population files, 0 of them left under `assets/`.
_opl_population() {
    git -C "$REPO_ROOT" ls-files -- \
        ':(glob)*.md' ':(glob)**/*.md' ':(glob)*.json' ':(glob)**/*.json' \
        ':(exclude)assets/' \
        | sort -u
}

# _opl_family <matched-line> — which declared family THIS LINE matches.
#
# THE ARGUMENT IS THE LINE, NEVER THE FILE PATH. The first draft passed the
# file, and every row duly came back `home-user` — a confident UNIFORM value,
# which is the tell CLAUDE.md names: when a per-item probe returns the same
# answer for every item, suspect it answered a question about their CONTAINER
# rather than about them. Nothing errored; the SHAPE of the output was the only
# evidence. Recorded here because the guard reproduced, on its first run, a
# member of the class it exists to catch.
#
# The families are disjoint by construction (distinct absolute prefixes), so no
# input matches two arms and arm ORDER cannot shadow a later one
# (your-org/nexus-code#1121). The default arm is reached only for `/home/…`,
# which is the sole remaining family.
_opl_family() {
    case "$1" in
        */shared/*/user/*) printf 'fh-user\n' ;;
        */Users/*)     printf 'macos-user\n' ;;
        *)             printf 'home-user\n' ;;
    esac
}

# Rows are per (file, FAMILY) pair: one file may ship literals of more than one
# shape, and collapsing them would hide a newly-introduced family behind an
# unchanged total.
_opl_scan() {
    local detail="${1:-}" f line fam
    while IFS= read -r f; do
        [ -f "$REPO_ROOT/$f" ] || continue
        local n_fh=0 n_home=0 n_mac=0
        while IFS= read -r line; do
            fam=$(_opl_family "$line")
            case "$fam" in
                fh-user)    n_fh=$((n_fh + 1)) ;;
                macos-user) n_mac=$((n_mac + 1)) ;;
                *)          n_home=$((n_home + 1)) ;;
            esac
            [ -n "$detail" ] && printf '%s\t%s\t%s\n' "$f" "$fam" "$line"
        done < <(grep -anE "$_OPL_RE" "$REPO_ROOT/$f" 2>/dev/null \
                   | grep -avE "$_OPL_GENERIC" || true)
        if [ -z "$detail" ]; then
            (( n_fh   > 0 )) && printf '%s\tfh-user\t%d\n'    "$f" "$n_fh"
            (( n_home > 0 )) && printf '%s\thome-user\t%d\n'  "$f" "$n_home"
            (( n_mac  > 0 )) && printf '%s\tmacos-user\t%d\n' "$f" "$n_mac"
        fi
    done < <(_opl_population)
    return 0
}

. "$_opl_lib_root/_guard_population.sh"
gp_population() {
    _opl_population                       # the guard's OWN enumerator
    printf '%s\n' 'monitor/watcher/operator-path-literals.manifest'
}
gp_handle "$@"

case "${1:-}" in
    --detail) _opl_scan detail ;;
    '')       _opl_scan ;;
    *)        printf 'usage: %s [--detail|--population]\n' "$0" >&2; exit 2 ;;
esac
