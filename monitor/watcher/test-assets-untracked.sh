#!/usr/bin/env bash
# test-assets-untracked.sh — the root `assets/` directory holds NO tracked
# files (your-org/nexus-code#1458).
#
# WHY THIS SUITE EXISTS. `/assets/` is gitignored by design: it is the mount
# point of the asset-repo clone, written by monitor/upload-asset.sh. Anything
# TRACKED there arrived by force-add through a misrouted uploader (#1173, the
# root cause, closed: `--repo` on the uploader is refused unless it restates
# the configured asset repo). Four wrap-up reports were tracked that way, sat
# in the implementation repo every operator clones, and were the reason a
# dev -> main promotion could never be a fast-forward. #1457 excluded `assets/`
# from the operator-path lint's population — correctly, a recording is not a
# doc surface — and in doing so removed the only DETECTOR of a future
# misroute. This is that detector, keyed on the property rather than on a
# lint about something else: the count of tracked paths under root `assets/`
# is ZERO, and a future misroute is a RED rather than a discovery.
#
# WHAT IS PINNED:
#   A  the live tree: `git ls-files -- ':(glob)assets/**'` is empty, AND the
#      positive control that the same predicate sees a tracked file elsewhere
#      (so an empty answer is not an inert instrument).
#   B  POTENCY, in a fixture repo: a force-added `assets/x.md` makes the same
#      predicate report 1 — the ratchet fires on exactly the shape it exists
#      for — and the ignore rule is in force (a plain `git add` refuses it).
#   C  the .gitignore rule itself is present, root-anchored, so the property
#      is enforced at the boundary and not only measured here.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

# ── this suite DECLARES its own population (the --population protocol) ──────
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        .gitignore \
        monitor/upload-asset.sh \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"

_tracked_under_assets() {   # <repo-root> -> count of tracked paths under root assets/
    git -C "$1" ls-files -z -- ':(glob)assets/**' | tr -cd '\0' | wc -c | tr -d ' '
}

echo '=== A: the live tree — root assets/ holds no tracked file ==='
n=$(_tracked_under_assets "$REPO_ROOT")
assert_eq "tracked paths under root assets/ (git ls-files -- ':(glob)assets/**')" "$n" "0"
# POSITIVE CONTROL: the instrument sees tracked files where they exist.
n_ctl=$(git -C "$REPO_ROOT" ls-files -z -- ':(glob)monitor/watcher/test-assets-untracked.sh' ':(glob)CLAUDE.md' | tr -cd '\0' | wc -c | tr -d ' ')
assert_eq "positive control: the same predicate counts 2 tracked files outside assets/ — so the 0 above is measured, not inert" "$n_ctl" "2"

echo '=== C: the ignore rule is present and root-anchored ==='
assert_eq ".gitignore carries the root-anchored /assets/ rule" \
    "$(grep -cx '/assets/' "$REPO_ROOT/.gitignore")" "1"

echo '=== B: potency — in a fixture repo a force-added assets/ file makes the ratchet fire ==='
WORK=$(mktemp -d) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
FX="$WORK/repo"
mkdir -p "$FX" && git -C "$FX" init -q && git -C "$FX" config user.email t@t && git -C "$FX" config user.name t
th_require_fixture_repo "$FX"
printf '/assets/\n' > "$FX/.gitignore"
mkdir -p "$FX/assets/873"
printf 'misrouted\n' > "$FX/assets/873/report.md"
git -C "$FX" add .gitignore && git -C "$FX" commit -q -m init
# A plain add is REFUSED by the ignore rule — the boundary holds…
git -C "$FX" add assets/873/report.md >/dev/null 2>&1; rc=$?
assert_eq "fixture: a plain git add of assets/873/report.md is refused by the ignore rule (rc 1)" "$rc" "1"
assert_eq "fixture: …and nothing under assets/ is tracked after it" "$(_tracked_under_assets "$FX")" "0"
# …and only a FORCE-add gets past it, which is exactly what this ratchet catches.
git -C "$FX" add -f assets/873/report.md && git -C "$FX" commit -q -m "misroute"
assert_eq "fixture: a force-added assets/ file makes the predicate report 1 — the ratchet FIRES" "$(_tracked_under_assets "$FX")" "1"

EXPECTED_ASSERTIONS=6
th_summary_and_exit
