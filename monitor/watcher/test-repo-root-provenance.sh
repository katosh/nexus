#!/usr/bin/env bash
# A PATH RESOLVED BY WALKING UP ANSWERS ABOUT THE WRONG REPOSITORY.
# your-org/nexus-code#1196 (read) + #1080 (write) + #1174 (silent hook).
#
# WHY ONE SUITE FOR THREE ISSUES. They are one defect class with one fix —
# `monitor/repo-root.sh` — and the guards for the three call sites are only
# meaningful together: each one asserts that a particular caller now asks the
# shared predicate instead of re-deriving the answer. Splitting them would
# also multiply this branch's contended-file debt (see the header note in the
# accompanying report): every new tracked `test-*.sh` reddens
# `test-summary-honesty-manifest.sh` until it is recorded, and both places
# that record it are files this branch is forbidden to touch.
#
# WHAT THIS SUITE TESTS IS THE DEFECT'S SHAPE, NOT THE FIX'S SHAPE. A guard
# that asserts `repo-root.sh is sourced` passes against a real regression in
# which the predicate is sourced and then ignored. So every section below
# drives the CALLER against a planted layout and asserts on its BEHAVIOUR,
# and §7 reverts each fix to its pre-`#1080` form and requires the assertion
# to flip.
#
# Run: bash monitor/watcher/test-repo-root-provenance.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
RR="$REPO_ROOT/monitor/repo-root.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rrprov.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
# MUTANT COPIES LIVE UNDER monitor/, SO $WORK's TRAP CANNOT REACH THEM
# (your-org/nexus-code#1247 (c)). They have to: each one `source`s a sibling by
# `$script_dir`, which is the round-2 fix for the inert mutant. Two consequences
# were measured — an interrupt between creation and removal LEFT the file behind
# (`?? monitor/.test-mutant-git-https-setup`), a near-copy of a production script
# sitting untracked in the working tree where the NEXT run's baseline is dirty
# and a repo-wide guard reads it as a tree offender; and two concurrent runs of
# this suite collided on the one FIXED name. So: pid-suffixed, and registered in
# the EXIT trap before either is created rather than rm'd inline afterwards.
_MUT_M1="$REPO_ROOT/monitor/.test-mutant-git-https-setup.$$"
_MUT_M5="$REPO_ROOT/monitor/.test-mutant-repo-root.$$.sh"
trap 'rm -f "$_MUT_M1" "$_MUT_M5"; chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# Fixture git must not read the operator's config, and must be able to commit.
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t
_g() { git "$@" >/dev/null 2>&1; }
_mkrepo() { _g init -q "$1" && ( cd "$1" && _g commit -q --allow-empty -m init ); }

# ── §0 THE PLANTS, AND PROOF THEY APPLIED ───────────────────────────────
# An inert fixture and a real surviving one give byte-identical output, so
# nothing below is read until every layout is shown to exist in the shape it
# is supposed to have. This is not decoration: an earlier draft of this file
# built its linked worktree inside a subshell whose `git commit` had no
# identity, `git worktree add` failed, and the whole layout table came back
# all-negative — which reads exactly like "the predicate rejects everything".
cd "$WORK" || { echo "FAIL: cd $WORK"; exit 1; }
_mkrepo enclosing
_mkrepo standalone
_mkrepo enclosing/nested
mkdir -p enclosing/plain
mkdir -p enclosing/interrupted/.git/objects          # the interrupted-clone stub
( cd standalone && _g worktree add -f "$WORK/linked-wt" -b wt )
mkdir -p sepdir && _g init -q --separate-git-dir "$WORK/sepdir/gd" "$WORK/sepwork" \
    && ( cd "$WORK/sepwork" && _g commit -q --allow-empty -m i )
_g init -q --bare "$WORK/bare.git"
mkdir -p "$WORK/bare.git/hooks/deeper/still"   # ANY depth inside a bare repo
mkdir -p "$WORK/notadir" && : > "$WORK/afile"  # exists, is not a directory
ln -s "$WORK/standalone" symrepo
ln -s "$WORK/enclosing/plain" symplain
mkdir -p "$WORK/noread/inner" && _g init -q "$WORK/noread/inner"
# A SUBMODULE and a LINKED WORKTREE are the same shape from outside — both are
# self-rooted and both have a `.git` FILE rather than a directory — and they
# need OPPOSITE answers. `--git-common-dir` is the only thing that separates
# them, which is why the predicate keys on it.
_g init -q submod-src && ( cd submod-src && echo x > f && _g add -A && _g commit -q -m i )
_g init -q super && ( cd super && _g commit -q --allow-empty -m i \
    && _g -c protocol.file.allow=always submodule add -q "$WORK/submod-src" mod \
    && _g commit -q -m addsub )

_plant_bad=""
_want() { [ -e "$WORK/$1" ] || _plant_bad="$_plant_bad $1"; }
_wantf() { [ -f "$WORK/$1" ] || _plant_bad="$_plant_bad $1(file)"; }
_want enclosing/.git; _want standalone/.git; _want enclosing/nested/.git
_want enclosing/plain; _want enclosing/interrupted/.git/objects
_wantf linked-wt/.git      # a linked worktree's .git is a FILE, not a directory
_wantf sepwork/.git
_want sepdir/gd/HEAD; _want bare.git/HEAD; _want symrepo; _want symplain
_want noread/inner/.git
_wantf super/mod/.git      # a submodule's .git is a FILE too — same shape as a worktree
_want bare.git/hooks/deeper/still
_want standalone/.git/hooks
_want afile
assert_eq "PLANT: every layout applied" "${_plant_bad:-none}" "none"
[ -z "$_plant_bad" ] || { echo "  refusing to read results off a broken layout" >&2; th_summary_and_exit; }

# ── §1 THE PREDICATE, ACROSS EVERY LAYOUT THAT CAN FOOL A NAIVE ONE ─────
_cd_probe() (
    . "$REPO_ROOT/monitor/watcher/_clone_drift.sh" >/dev/null 2>&1
    _clone_drift_probe "$1" dev
)

_kind() { bash "$RR" --kind "$1" 2>/dev/null; }
_rc()   { bash "$RR" --quiet "$1" >/dev/null 2>&1; printf '%s' "$?"; }
_verdict_of() { printf '%s/%s' "$(_rc "$1")" "$(_kind "$1")"; }

assert_eq "a non-repo subdir is NO (the #1196 read hazard)" \
    "$(_verdict_of "$WORK/enclosing/plain")" "1/subdir"
assert_eq "an INTERRUPTED CLONE stub is NO (the #1080 arm-1 hole)" \
    "$(_verdict_of "$WORK/enclosing/interrupted")" "1/gitdir-stub"
assert_eq "a repo NESTED in a repo is its own root" \
    "$(_verdict_of "$WORK/enclosing/nested")" "0/root"
assert_eq "a plain repo root is YES" \
    "$(_verdict_of "$WORK/standalone")" "0/root"
assert_eq "a SYMLINK to a repo root is YES (pwd -P on both sides)" \
    "$(_verdict_of "$WORK/symrepo")" "0/root"
assert_eq "a SYMLINK to a non-repo is NO" \
    "$(_verdict_of "$WORK/symplain")" "1/subdir"
assert_eq "a --separate-git-dir checkout is YES (#1080's own form says NO)" \
    "$(_verdict_of "$WORK/sepwork")" "0/root"
assert_eq "a BARE repo is YES, and is named as bare" \
    "$(_verdict_of "$WORK/bare.git")" "0/bare"
assert_eq "a LINKED WORKTREE is NO for the write question" \
    "$(_verdict_of "$WORK/linked-wt")" "1/linked-worktree"
assert_eq "a path that does not exist is NO (positively established)" \
    "$(_verdict_of "$WORK/nosuchdir")" "1/absent"
assert_eq "a path that exists but is NOT a directory is NO" \
    "$(_verdict_of "$WORK/afile")" "1/absent"

# ── §1a ARM-ORDER SHADOWING, THE HOLE THIS FILE ONCE HAD (round 2) ──────
# `--is-bare-repository` is TRUE for every directory at ANY DEPTH inside a
# bare repository. The bare arm used to be decided BEFORE the arm that asks
# whether `$dir` is the repository at all, so `bare.git/hooks/deeper/still`
# answered `verdict=yes kind=bare` — a permissive SAFE arm returning before a
# DENY arm that would have caught the same input, i.e. `#1121` in the file
# whose header cites `#1121`. It was a WRITE hole in the class this PR exists
# to close: `git-https-setup --repo bare.git/hooks/deep` was NOT refused, and
# `work/lab-wiki.git` on this host is a real bare repo.
#
# Depth is varied on purpose: a fix that special-cases only the immediate
# child would pass a single-depth test.
assert_eq "a BARE repo's ROOT is YES" "$(_verdict_of "$WORK/bare.git")" "0/bare"
assert_eq "depth 1 inside a bare repo is NO"  "$(_verdict_of "$WORK/bare.git/hooks")" "1/inside-gitdir"
assert_eq "depth 2 inside a bare repo is NO"  "$(_verdict_of "$WORK/bare.git/hooks/deeper")" "1/inside-gitdir"
assert_eq "depth 3 inside a bare repo is NO"  "$(_verdict_of "$WORK/bare.git/hooks/deeper/still")" "1/inside-gitdir"

# The NON-bare git dir is the control that stops the repair being "compare
# real to the git dir": measured, `<repo>/.git` reports is-bare=FALSE with an
# EMPTY toplevel, so a `real == gitdir` test alone would have called it bare.
assert_eq "a repo's OWN .git dir is NO, and is not 'bare'" \
    "$(_verdict_of "$WORK/standalone/.git")" "1/gitdir-itself"
assert_eq "inside a non-bare repo's .git is NO (not UNDETERMINED)" \
    "$(_verdict_of "$WORK/standalone/.git/hooks")" "1/inside-gitdir"

# The WRITE consequence, driven through the real caller.
_bare_deep=$(bash "$REPO_ROOT/monitor/git-https-setup" --repo "$WORK/bare.git/hooks/deeper" 2>&1)
assert_contains "git-https-setup REFUSES a path inside a bare repo" \
    "$_bare_deep" "is not a git repository rooted at itself"
_bare_root=$(bash "$REPO_ROOT/monitor/git-https-setup" --repo "$WORK/bare.git" 2>&1)
assert_not_contains "POSITIVE CONTROL: the bare repo's own root is NOT refused" \
    "$_bare_root" "is not a git repository rooted at itself"

# ── §1b THE THREE-VALUED CONTRACT ───────────────────────────────────────
# UNDETERMINED IS NOT NO. Collapsing it is the whole reason this is not a
# boolean: a newer git refusing a directory for dubious ownership exits 128 on
# a path that IS a repository root, and a two-valued caller records that as
# "not a repo" and proceeds.
chmod 000 "$WORK/noread"
assert_eq "an UNENTERABLE directory is UNDETERMINED (3), not NO" \
    "$(_verdict_of "$WORK/noread/inner")" "3/unreadable"
# THE MODE-000 DIRECTORY ITSELF, not its child. The first fix handled the
# child (whose parent is unsearchable, so `stat` fails) and left the sibling:
# `stat` SUCCEEDS on a mode-000 directory whose parent is searchable, the old
# ladder asked the parent first, and the answer came back `kind=absent
# verdict=no` — byte-identical to a path that does not exist. That made
# `_clone_drift_probe`'s `repo_root_undetermined` arm unreachable for the one
# input it was written for.
assert_eq "a MODE-000 DIRECTORY ITSELF is UNDETERMINED (3), not 'absent'" \
    "$(_verdict_of "$WORK/noread")" "3/unreadable"
assert_contains "  ...and clone-drift says so, rather than 'not a git repo'" \
    "$(_cd_probe "$WORK/noread")" "reason=repo_root_undetermined"
chmod 755 "$WORK/noread"
_nogit=$(env PATH=/nonexistent /bin/bash "$RR" "$WORK/standalone" 2>&1); _nogit_rc=$?
assert_eq "no usable git is UNDETERMINED (3), not NO" "$_nogit_rc" "3"
assert_contains "  ...and it says which" "$_nogit" "kind=git-unavailable"

# ── §1c THE READ QUESTION IS NOT THE WRITE QUESTION ─────────────────────
# A linked worktree's HEAD is honestly its own, but `git -C <wt> config
# --local` writes into the MAIN repository. One boolean cannot be right about
# both, so there are two named questions.
_hist() { bash "$RR" --history "$1" >/dev/null 2>&1; printf '%s' "$?"; }
assert_eq "READ: a linked worktree HAS its own history"  "$(_hist "$WORK/linked-wt")" "0"
assert_eq "WRITE: the same worktree is NOT its own root" "$(_rc   "$WORK/linked-wt")" "1"
assert_eq "READ: a non-repo subdir has NO history of its own" "$(_hist "$WORK/enclosing/plain")" "1"

# A SUBMODULE IS THE CONTROL THAT STOPS "a .git FILE means not your own repo"
# from becoming the rule. It looks exactly like a linked worktree from
# outside — self-rooted, `.git` is a file — and it needs the OPPOSITE answer,
# because `git -C <submodule> config --local` was measured landing in the
# submodule's OWN config (`<super>/.git/modules/mod/config`) and NOT in the
# superproject's. `--git-common-dir` is what tells the two apart.
assert_eq "a SUBMODULE work tree is its own root (unlike a linked worktree)" \
    "$(_verdict_of "$WORK/super/mod")" "0/root"
git -C "$WORK/super/mod" config --local rrprov.sm landed >/dev/null 2>&1
assert_eq "  ...and its --local config does NOT reach the superproject" \
    "$(git -C "$WORK/super" config --local --get rrprov.sm 2>/dev/null || printf none)" "none"

# ── §2 NEGATIVE CONTROLS: THE PUBLISHED DISCRIMINATORS ARE WRONG HERE ───
# `#1196` names two forms and presents them as interchangeable. Each of the
# three assertions below shows a published form giving the WRONG answer on a
# layout the helper gets right. Without these, §1 is just "the code does what
# the code does".
_pub_toplevel() {  # #1196 form A
    [ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$1" && pwd -P)" ]
}
_pub_prefix() {    # #1196 form B
    [ -z "$(git -C "$1" rev-parse --show-prefix 2>/dev/null)" ]
}
_yn() { if "$@"; then printf yes; else printf no; fi; }

# HOLE 1 — a linked worktree passes BOTH published forms, and its --local
# config lands in the main repository.
assert_eq "HOLE 1: form A says YES for a linked worktree" \
    "$(_yn _pub_toplevel "$WORK/linked-wt")" "yes"
assert_eq "HOLE 1: form B says YES for a linked worktree" \
    "$(_yn _pub_prefix "$WORK/linked-wt")" "yes"
git -C "$WORK/linked-wt" config --local rrprov.witness landed-here >/dev/null 2>&1
assert_eq "HOLE 1: ...and --local config lands in the MAIN repo, not the worktree" \
    "$(git -C "$WORK/standalone" config --local --get rrprov.witness 2>/dev/null)" "landed-here"
assert_eq "HOLE 1: the helper refuses it" "$(_rc "$WORK/linked-wt")" "1"

# HOLE 2 — the two published forms DISAGREE on a bare repository, so they are
# not interchangeable and "use either" is not advice.
assert_eq "HOLE 2: form A says NO for a bare repo"  "$(_yn _pub_toplevel "$WORK/bare.git")" "no"
assert_eq "HOLE 2: form B says YES for a bare repo" "$(_yn _pub_prefix  "$WORK/bare.git")" "yes"

# HOLE 3 — an inherited GIT_DIR fools BOTH. Git sets GIT_DIR for every hook it
# runs, so anything invoked from a git hook inherits it.
_poison() { GIT_DIR="$WORK/standalone/.git" GIT_WORK_TREE="$WORK/enclosing/plain" "$@"; }
assert_eq "HOLE 3: form A says YES for a NON-repo under an inherited GIT_DIR" \
    "$(_poison bash -c '[ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$1" && pwd -P)" ] && echo yes || echo no' _ "$WORK/enclosing/plain")" "yes"
assert_eq "HOLE 3: form B says YES for the same directory" \
    "$(_poison bash -c '[ -z "$(git -C "$1" rev-parse --show-prefix 2>/dev/null)" ] && echo yes || echo no' _ "$WORK/enclosing/plain")" "yes"
assert_eq "HOLE 3: the helper still says NO under the same environment" \
    "$(_poison bash "$RR" --quiet "$WORK/enclosing/plain" >/dev/null 2>&1; printf '%s' "$?")" "1"
assert_eq "HOLE 3: ...and still says YES for a real root under it" \
    "$(_poison bash "$RR" --quiet "$WORK/standalone" >/dev/null 2>&1; printf '%s' "$?")" "0"

# ── §3 THE WRITE HAZARD: git-https-setup MUST NOT TOUCH THE ENCLOSING REPO ──
# The assertion is on the ENCLOSING repository's config, not on the tool's
# output — `#1080`'s whole point is that the tool said nothing about which
# repo it wrote to.
git -C "$WORK/enclosing" config --local user.name Operator >/dev/null 2>&1
for _target in "$WORK/enclosing/interrupted" "$WORK/enclosing/plain" "$WORK/linked-wt"; do
    _out=$(bash "$REPO_ROOT/monitor/git-https-setup" --repo "$_target" 2>&1); _hrc=$?
    assert_eq "git-https-setup REFUSES ${_target##*/}" "$_hrc" "1"
    assert_contains "  ...and its refusal names the kind" "$_out" "is not a git repository rooted at itself"
done
assert_eq "the ENCLOSING repo's user.name is untouched" \
    "$(git -C "$WORK/enclosing" config --local --get user.name)" "Operator"
assert_eq "the ENCLOSING repo acquired NO credential helper" \
    "$(git -C "$WORK/enclosing" config --local --get-all credential.https://github.com.helper 2>/dev/null | grep -c . || true)" "0"
assert_contains "the linked-worktree refusal names where the write WOULD have gone" \
    "$(bash "$REPO_ROOT/monitor/git-https-setup" --repo "$WORK/linked-wt" 2>&1)" "writes into the MAIN repository"

# POSITIVE CONTROL — the guard must not simply refuse everything. A real repo
# root gets PAST it; the tool then fails downstream on this host because
# `github.bot_git_name` is absent from config/nexus.yml (a pre-existing gap,
# unrelated to this change and present on clean `dev`). Reaching `load.sh` at
# all is the proof, since it is read strictly after the guard.
_pc=$(bash "$REPO_ROOT/monitor/git-https-setup" --repo "$WORK/standalone" 2>&1)
assert_not_contains "POSITIVE CONTROL: a real repo root is NOT refused by the guard" \
    "$_pc" "is not a git repository rooted at itself"

# ── §4 THE READ HAZARD IN THE DEPLOYMENT GATE ───────────────────────────
assert_contains "clone-drift refuses a walk-up root" \
    "$(_cd_probe "$WORK/enclosing/plain")" "reason=not_a_git_repo"
assert_contains "clone-drift refuses an interrupted-clone stub" \
    "$(_cd_probe "$WORK/enclosing/interrupted")" "reason=not_a_git_repo"

# ── §5 THE INSTALLER PREDICATE ──────────────────────────────────────────
_inst() (
    . "$REPO_ROOT/monitor/_install-lib.sh" >/dev/null 2>&1
    install_dir_is_repo "$1" && printf yes || printf no
)
assert_eq "install_dir_is_repo: an interrupted-clone stub is NOT a repo" \
    "$(_inst "$WORK/enclosing/interrupted")" "no"
assert_eq "install_dir_is_repo: a real repo root IS one" \
    "$(_inst "$WORK/standalone")" "yes"
assert_eq "install_dir_is_repo: a --separate-git-dir checkout IS one (.git is a FILE)" \
    "$(_inst "$WORK/sepwork")" "yes"

# ── §5a THE THREE-VALUED CONTRACT AT A GATE THAT MOVES A DIRECTORY ASIDE ──
# `install_dir_is_repo() { rr_has_own_history "$1"; }` looked like a faithful
# wrapper and was not: `rc 3` is non-zero, so
#
#     if install_dir_is_repo "$t" && ! install_remote_matches …; then die …; fi
#     mv "$t" "$bak"
#
# SKIPPED the refusal for a target nobody could examine and fell through to
# the rename. The three-valued contract violated by a ONE-LINE WRAPPER at one
# of the very sites this change converted (your-org/nexus-code#1243 round 2).
_inst_state() (
    . "$REPO_ROOT/monitor/_install-lib.sh" >/dev/null 2>&1
    install_dir_repo_state "$1"; printf '%s' "$?"
)
chmod 000 "$WORK/noread"
assert_eq "install_dir_repo_state: an unexaminable target is 3, not 1" \
    "$(_inst_state "$WORK/noread/inner")" "3"
assert_eq "install_dir_is_repo FAILS CLOSED on undetermined (careful branch)" \
    "$(_inst "$WORK/noread/inner")" "yes"
chmod 755 "$WORK/noread"
assert_eq "  ...and still says NO for a directory that is positively not a repo" \
    "$(_inst "$WORK/enclosing/plain")" "no"

# The shipped gate itself must refuse rather than fall through.
_gate_out=$(chmod 000 "$WORK/noread"
    ( . "$REPO_ROOT/monitor/_install-lib.sh" >/dev/null 2>&1
      target="$WORK/noread/inner"
      install_dir_repo_state "$target"
      if [ "$?" -eq 3 ]; then printf 'REFUSED'; else printf 'FELL-THROUGH-TO-MV'; fi )
    chmod 755 "$WORK/noread")
assert_eq "the overwrite gate REFUSES an unexaminable target" "$_gate_out" "REFUSED"

# ── §5b A PATH WITH A SPACE (HOLE 8) ────────────────────────────────────
# "Naming the repository git would have acted on" is this change's headline
# improvement over `#1080`, and it was recovered by splitting the key=value
# line on whitespace — so under a path containing a space it named a
# TRUNCATED path that does not exist. Both surfaces failed on the same input:
# the line is documented as machine-readable and was not parseable either.
_sp="$WORK/has space"
mkdir -p "$_sp" && _mkrepo "$_sp/enc" && mkdir -p "$_sp/enc/plain"
assert_eq "PLANT: the space fixture exists" "$([ -d "$_sp/enc/plain" ] && printf yes || printf no)" "yes"
_sp_out=$(bash "$REPO_ROOT/monitor/git-https-setup" --repo "$_sp/enc/plain" 2>&1)
_sp_named=$(printf '%s' "$_sp_out" | sed -n 's/.*acted on \(.*\) instead.*/\1/p')
assert_eq "the diagnostic names a path that EXISTS" \
    "$([ -n "$_sp_named" ] && [ -e "$_sp_named" ] && printf yes || printf no)" "yes"
assert_eq "  ...and it is the enclosing repo, not a prefix of it" "$_sp_named" "$_sp/enc"
# The MACHINE surface: the line must survive `eval`.
_sp_line=$(bash "$REPO_ROOT/monitor/repo-root.sh" "$_sp/enc/plain")
_sp_top=$( eval "$_sp_line"; printf '%s' "$top" )
assert_eq "the key=value line round-trips a path with a space" "$_sp_top" "$_sp/enc"

# ── §6 THE HOOK TEMPLATE (#1174) ────────────────────────────────────────
TPL="$REPO_ROOT/monitor/boot-recover.session-start-hook.json"
_tpl_cmd=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['hooks']['SessionStart'][0]['hooks'][0]['command'])" "$TPL" 2>/dev/null)
assert_eq "the template ships a PLACEHOLDER, not an operator's absolute path" \
    "$_tpl_cmd" "<YOUR_NEXUS_ROOT>/monitor/boot-recover.sh"
# ASSERT THE PROPERTY, NOT ONE OPERATOR'S SPELLING OF IT. `no /shared/`
# would be VACUOUSLY TRUE on every host but this one, so it could not catch a
# DIFFERENT operator's path being reintroduced — which is `#1174` exactly. The
# property is that the command is not an absolute path at all.
assert_eq "the template's command is not an ABSOLUTE path (any operator's)" \
    "$(case "$_tpl_cmd" in /*) printf absolute ;; *) printf placeholder ;; esac)" "placeholder"

# THE PLACEHOLDER ALONE IS NOT THE FIX, AND THIS IS THE ASSERTION THAT SAYS SO.
# Measured against Claude Code 2.1.246 with a positive control that did fire: a
# SessionStart hook whose command does not exist is SILENT ON EVERY CHANNEL A
# `-p` CALLER OR A HUMAN SEES BY DEFAULT — stdout, stderr and rc byte-identical
# to no hooks at all, for both `async` settings and both matchers. It IS
# recorded in the session transcript (an extra `async_hook_response`
# attachment carrying exitCode 127), in `--output-format stream-json
# --verbose`, and in `--debug-file`; none of those is on by default.
#
# An earlier version of this comment said "completely silent, --debug
# included". That was wrong, and the way it was wrong is the part worth
# keeping: `--debug` routes nothing in `-p` mode, so its 160 bytes name no
# hook in EVERY arm INCLUDING THE WORKING ONE. The positive control proved the
# HOOK fired; it could not prove the INSTRUMENT reported, because it was read
# through the same dead channel.
#
#   A POSITIVE CONTROL ON THE SUBJECT IS NOT A POSITIVE CONTROL ON THE
#   OBSERVER, and a negative scoped to one output channel is not a negative.
#
# What survives unchanged: an unreplaced placeholder is as invisible in
# practice as a wrong absolute path, so the out-of-session check is still the
# mechanism.
_spliced="$WORK/spliced-settings.json"
python3 -c "import json,sys;t=json.load(open(sys.argv[1]));json.dump({'hooks':t['hooks']},open(sys.argv[2],'w'))" "$TPL" "$_spliced"
bash "$REPO_ROOT/monitor/boot-recover-hook-check.sh" --settings "$_spliced" >/dev/null 2>&1
assert_eq "the template spliced VERBATIM is reported NOT ARMED (rc 1)" "$?" "1"

# ARMED means "runs THIS checkout's primary". From a secondary clone
# (`<primary>/work/<project>-<task>/`, the prescribed shape for watcher work)
# `$REPO_ROOT/monitor/boot-recover.sh` is NOT the primary, so the fixture below
# resolves the primary the same way the checker does — the repo's one resolver
# (your-org/nexus-code#577, #1077). That IS a cross-check that could agree with
# itself if `nexus_primary_root` were wrong, so the arms that follow it do not
# depend on the resolver at all.
_PRIMARY_BR=$(bash -c '. "$1/monitor/_nexus-root.sh"; nexus_primary_root "$1"' _ "$REPO_ROOT")/monitor/boot-recover.sh
assert_eq "the resolved primary boot-recover.sh exists and is executable" \
    "$( [ -x "$_PRIMARY_BR" ] && printf yes || printf no )" "yes"

_mkhook() {   # <out.json> <command> [matcher|NONE]
    python3 -c "
import json,sys
g = {} if sys.argv[3] == 'NONE' else {'matcher': sys.argv[3]}
g['hooks'] = [{'type':'command','command':sys.argv[2],'async':True}]
json.dump({'hooks':{'SessionStart':[g]}}, open(sys.argv[1],'w'))" "$1" "$2" "${3:-resume}"
}
_hookrc() { bash "$REPO_ROOT/monitor/boot-recover-hook-check.sh" --settings "$1" >/dev/null 2>&1; printf '%s' "$?"; }

_armed="$WORK/armed-settings.json"
_mkhook "$_armed" "$_PRIMARY_BR"
assert_eq "POSITIVE CONTROL: a correctly wired hook is ARMED (rc 0)" "$(_hookrc "$_armed")" "0"

# ── #1247 (b) IDENTITY IS AN OWNED MARKER, NOT A BASENAME ────────────────
# A two-line `#!/bin/sh\nexit 0` named boot-recover.sh, ANYWHERE on the host,
# used to report ARMED rc 0 with only a NOTE on stdout — which `--quiet`
# suppresses and a caller reading the exit code never sees. So the documented
# contract ("treat its exit code as the evidence that recovery is armed") was
# satisfied by a script that does nothing: the same false clearance this tool
# was rebuilt to remove, one level in.
_imp="$WORK/impostor"; mkdir -p "$_imp"
printf '#!/bin/sh\nexit 0\n' > "$_imp/boot-recover.sh"; chmod +x "$_imp/boot-recover.sh"
_mkhook "$WORK/impostor.json" "$_imp/boot-recover.sh"
assert_eq "#1247(b): an impostor named boot-recover.sh is NOT ARMED (rc 1), not ARMED" \
    "$(_hookrc "$WORK/impostor.json")" "1"
assert_contains "  …and the refusal is on STDERR, so --quiet cannot hide it" \
    "$(bash "$REPO_ROOT/monitor/boot-recover-hook-check.sh" --quiet --settings "$WORK/impostor.json" 2>&1 >/dev/null)" \
    "does NOT carry the nexus"

# A DIFFERENT nexus's copy is legitimate but does not arm THIS checkout: its own
# exit code, not a silent rc 0.
_oth="$WORK/othernexus/monitor"; mkdir -p "$_oth"
# Copied from THIS checkout — the file under test, so it carries the marker by
# construction. Copying the PRIMARY's would make the fixture depend on a tree
# this suite does not control when it runs from a secondary clone.
cp "$REPO_ROOT/monitor/boot-recover.sh" "$_oth/boot-recover.sh"; chmod +x "$_oth/boot-recover.sh"
_mkhook "$WORK/other.json" "$_oth/boot-recover.sh"
assert_eq "#1247(b): another nexus's boot-recover.sh is ARMED ELSEWHERE (rc 5), not 0" \
    "$(_hookrc "$WORK/other.json")" "5"

# ── #1247 (a) THE COMMAND IS SPLIT BY THE SHELL'S RULES, NOT AT THE FIRST SPACE
# `${_cmd%% *}` named a truncated path for a quoted path containing a space, and
# named `sh` for an `sh -c 'exec …'` wrapper — reporting OTHER, i.e. "somebody
# else's hook", for a correctly wired one. Fail-safe in direction, still a false
# negative on a working configuration.
_sp="$WORK/has space/monitor"; mkdir -p "$_sp"
cp "$REPO_ROOT/monitor/boot-recover.sh" "$_sp/boot-recover.sh"; chmod +x "$_sp/boot-recover.sh"
_mkhook "$WORK/space.json" "\"$_sp/boot-recover.sh\""
assert_eq "#1247(a): a QUOTED path containing a space is resolved, not truncated" \
    "$(_hookrc "$WORK/space.json")" "5"
_mkhook "$WORK/shc.json" "sh -c 'exec $_oth/boot-recover.sh'"
assert_eq "#1247(a): an 'sh -c exec …' wrapper resolves the inner script, not sh" \
    "$(_hookrc "$WORK/shc.json")" "5"

# ── FOUND WHILE REPRODUCING (a): AN OMITTED `matcher` COLLAPSED EVERY FIELD ──
# The parser emitted TAB-separated records and `matcher` is OPTIONAL in Claude
# Code. Tab is IFS *whitespace*, so bash collapses a run of them and drops empty
# fields: `CMD\t\tFalse\t<cmd>` shifted every field left, leaving the COMMAND in
# `_async` and `_cmd` EMPTY. The tool then reported OTHER / NOT ARMED for a
# correctly wired hook and could not report ARMED for ANY matcher-less
# configuration — fail-safe in direction, total as a blind spot. Records now use
# \x1f, which is not IFS whitespace.
_mkhook "$WORK/nomatcher.json" "$_PRIMARY_BR" NONE
assert_eq "a hook with NO matcher at all is still ARMED (rc 0)" \
    "$(_hookrc "$WORK/nomatcher.json")" "0"

# THE FALSE CLEARANCE (round 2). The checker asked "is SOME SessionStart
# command executable?", so `/bin/true` alone reported ARMED rc 0 while
# `boot-recover.sh` was wired nowhere — `#1174` regenerated inside its own
# remedy. A checker that says ARMED when nothing is armed is worse than none.
_true_only="$WORK/true-only.json"
printf '{"hooks":{"SessionStart":[{"matcher":"resume","hooks":[{"type":"command","command":"/bin/true","async":true}]}]}}\n' > "$_true_only"
bash "$REPO_ROOT/monitor/boot-recover-hook-check.sh" --settings "$_true_only" >/dev/null 2>&1
assert_eq "an unrelated executable hook is NOT ARMED (rc 1), not ARMED" "$?" "1"
assert_contains "  ...and the refusal names what is actually expected" \
    "$(bash "$REPO_ROOT/monitor/boot-recover-hook-check.sh" --settings "$_true_only" 2>&1)" \
    "no SessionStart hook runs boot-recover.sh"
# ...and a real hook ALONGSIDE an unrelated one is still ARMED.
_mixed="$WORK/mixed.json"
python3 -c "
import json,sys
json.dump({'hooks':{'SessionStart':[{'matcher':'resume','hooks':[
  {'type':'command','command':'/bin/true','async':True},
  {'type':'command','command':sys.argv[2],'async':True}]}]}}, open(sys.argv[1],'w'))" \
  "$_mixed" "$_PRIMARY_BR"
bash "$REPO_ROOT/monitor/boot-recover-hook-check.sh" --settings "$_mixed" >/dev/null 2>&1
assert_eq "a real hook alongside an unrelated one is still ARMED (rc 0)" "$?" "0"

# ── §6a THE REFUTED SENTENCE MUST NOT COME BACK ─────────────────────────
# The false claim shipped in FOUR files, and that is the reason it is a
# blocker rather than a note: these are exactly the artefacts that get COPIED,
# which is how `#1174` propagates in the first place. A prose correction with
# no ratchet is a correction that lasts until the next person quotes the old
# wording from a neighbouring file.
#
# The predicate is deliberately narrow — it forbids the two ASSERTIONS that
# were wrong, not the words. The corrected texts below all discuss the claim
# in order to disavow it, so a bare `grep -i "completely silent"` would flag
# the fix as the defect.
# THE EXEMPTION IS AN OWNED MARKER, NOT AN ENGLISH PHRASE (your-org/nexus-code#1247 (d)).
# It used to exempt any candidate line carrying `earlier version|used to say|…`,
# evaluated ON THE SAME LINE — so prefixing the refuted sentence with an
# exempting phrase carried it straight through, and the guard stayed green while
# the sentence shipped. The exemption was written to recognise a DISAVOWAL and
# it recognised a WORD.
#
# Measured before changing it: the predicate matches ZERO lines across all four
# files, so the exemption arm was also UNEXERCISED in production — tightening it
# costs nothing today and its bypass had never been needed.
#
# `#1174-REFUTED-QUOTE` cannot be typed by accident, which is the whole
# difference: an English phrase is prose an author may reach for innocently, a
# marker is a deliberate act a reviewer sees in the diff. It is honoured on the
# candidate line OR the line before it — BOTH positions, because one of the four
# scanned files is JSON whose values are single enormous lines, and a
# preceding-line-only rule would be unusable there.
_REFUTED_MARK='#1174-REFUTED''-QUOTE'
_refuted_scan() {   # <file> -> line numbers that ASSERT the refuted claim, unmarked
    awk -v MARK="$_REFUTED_MARK" '
        { L[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (L[i] !~ /does not exist is (completely|entirely) silent/ &&
                    L[i] !~ /nothing inside the session will ever/) continue
                if (index(L[i], MARK)) continue
                if (i > 1 && index(L[i-1], MARK)) continue
                print i
            }
        }' "$1"
}

_refuted_hits=""
for _f in "$REPO_ROOT/monitor/boot-recover.session-start-hook.json" \
          "$REPO_ROOT/monitor/agent-prompt.md" \
          "$REPO_ROOT/monitor/boot-recover-hook-check.sh" \
          "$REPO_ROOT/docs/reference/files.md"; do
    [ -r "$_f" ] || { _refuted_hits="$_refuted_hits MISSING:${_f##*/}"; continue; }
    _rl=$(_refuted_scan "$_f")
    [ -z "$_rl" ] || _refuted_hits="$_refuted_hits ${_f##*/}:$(printf '%s' "$_rl" | tr '\n' ',')"
done
assert_eq "no shipped file still ASSERTS the refuted '#1174' claim" "${_refuted_hits:-none}" "none"

# POSITIVE CONTROLS — the predicate must be able to fire AND the exemption must
# be able to refuse. A guard shown only to say "none" is the shape this suite
# exists to refuse, and the OLD exemption had no control of its own at all: the
# one below it drove the raw `grep`, bypassing the exemption filter entirely, so
# nothing ever exercised the arm that `#1247` (d) walked through.
_planted="$WORK/refuted-plant.md"
printf 'a hook whose command does not exist is completely silent in Claude Code\n' > "$_planted"
assert_eq "POSITIVE CONTROL: the predicate DOES flag the refuted sentence" \
    "$(_refuted_scan "$_planted")" "1"

# #1247 (d)'s OWN BYPASS, kept permanent. This exact line shipped the refuted
# sentence through the old exemption and left the suite at ALL TESTS PASSED.
_planted_bypass="$WORK/refuted-bypass.md"
printf 'As an earlier version noted, a hook whose command does not exist is completely silent\n' \
    > "$_planted_bypass"
assert_eq "POSITIVE CONTROL: prefixing an exempting PHRASE no longer carries it through" \
    "$(_refuted_scan "$_planted_bypass")" "1"

# …and the exemption still works where it is meant to, in both positions, or a
# genuine correction could not quote the claim in order to disavow it.
_planted_marked="$WORK/refuted-marked.md"
{ printf 'a hook whose command does not exist is completely silent   <!-- %s -->\n' "$_REFUTED_MARK"
  printf '<!-- %s -->\n' "$_REFUTED_MARK"
  printf 'nothing inside the session will ever tell you, an earlier claim now withdrawn\n'
} > "$_planted_marked"
assert_eq "POSITIVE CONTROL: the OWNED marker exempts, same line and preceding line" \
    "$(_refuted_scan "$_planted_marked")" ""

printf '{"hooks":{"Stop":[]}}\n' > "$WORK/nohook.json"
bash "$REPO_ROOT/monitor/boot-recover-hook-check.sh" --settings "$WORK/nohook.json" >/dev/null 2>&1
assert_eq "no SessionStart hook at all is ABSENT (4), not 'not armed'" "$?" "4"
printf 'not json\n' > "$WORK/broken.json"
bash "$REPO_ROOT/monitor/boot-recover-hook-check.sh" --settings "$WORK/broken.json" >/dev/null 2>&1
assert_eq "unreadable settings is UNDETERMINED (3), not 'not armed'" "$?" "3"

# ── §7 MUTANTS — EACH GUARD MUST BE ABLE TO FAIL ────────────────────────
#
# THE STANDING FORM IS  APPLIED + PARSES + REACHED.  All three, for every
# mutant, and the third is not optional:
#
#   APPLIED  the mutant's bytes differ from the original;
#   PARSES   `bash -n` is clean, so its silence is not a syntax error;
#   REACHED  an arm in which THE MUTATED CODE ITSELF SPEAKS, or in which its
#            return value is directly observed.
#
# The third was added because mutant 1 satisfied the first two and was INERT
# (your-org/nexus-code#1243 round 2). Written outside `monitor/`, it died at
# its `. "$script_dir/repo-root.sh"` line under `set -euo pipefail` and never
# reached the guard — while the `assert_not_contains` beneath it passed
# VACUOUSLY against empty output, which is the exact shape of a guard that
# has only ever been shown to say yes.
#
#   `bash -n` CANNOT SEE A RUNTIME `source` FAILURE, so PARSE-PROOF IS NOT
#   RUN-PROOF. A mutant is a measuring instrument; the instrument needs its
#   own positive control, exactly as the `#1174` `--debug` arm did.
#
# Mutants 2 and 3 are shell functions defined here and CALLED directly by
# their assertions, so the assertion IS the reached-proof: their return value
# cannot be observed without them running. Mutants 1 and 4 are files, so each
# carries an explicit reached-proof arm below.
# A guard that has only ever been shown to say yes is not a guard. Each mutant
# below restores the PRE-FIX predicate and requires the corresponding
# assertion to flip.
#
# EVERY MUTANT IS PROVEN APPLIED **AND** PROVEN TO PARSE BEFORE ITS RESULT IS
# READ, and both halves were learned here rather than foreseen. An earlier
# draft built mutant 1 with a `sed 's|…||…|'` whose replacement text contained
# the `||` operator; sed rejected the expression, wrote an EMPTY file, and
# `cmp -s` duly reported "changed" — so the applied-proof PASSED for a mutant
# that did not exist, and the `assert_not_contains` below it passed vacuously
# against empty output. An inert mutant and a real surviving one are
# indistinguishable from output alone, which is the whole reason these
# assertions are here; a proof that can be satisfied by a broken mutant is not
# one. So: content differs, `bash -n` is clean, AND the restored text is
# present by name.
#
# MUTANT 1 MUST LIVE INSIDE `monitor/`, AND THAT IS THE WHOLE LESSON HERE.
# Written to $WORK — which is what the first version did — the mutant dies at
# its `. "$script_dir/repo-root.sh"` line under `set -euo pipefail`, because
# `$script_dir` is then $WORK and there is no `repo-root.sh` there. It never
# reaches the guard at all. And it passed ALL THREE proofs above it: content
# differed, `bash -n` was clean, and the restored text was present by name —
# while the assertion below passed VACUOUSLY against empty output.
#
#   PARSE-PROOF IS NOT RUN-PROOF. `bash -n` cannot see a runtime `source`
#   failure, so "it parses" says nothing about whether the line under test is
#   ever reached. The only proof that a mutant is live is an arm in which the
#   MUTATED CODE ITSELF SPEAKS.
#
# So the mutant is sited beside the original, and §7a below is a positive
# control that drives it to a target the OLD guard REFUSES and requires the
# old guard's OWN message. Only then is its acceptance of the stub evidence.
_m1="$_MUT_M1"
python3 - "$REPO_ROOT/monitor/git-https-setup" "$_m1" <<'MUT1'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
new_line = ('[[ -d "$target/.git" ]] || git -C "$target" rev-parse '
            '--is-inside-work-tree >/dev/null 2>&1 || { '
            'echo "MUTANT-OLD-GUARD: not a git repo" >&2; exit 1; }')
old_line = 'rr_require_own_root "$target" "git-https-setup" || exit 1'
assert old_line in s, "anchor missing"
open(dst, "w").write(s.replace(old_line, new_line, 1))
MUT1
_m1_rc=$?
assert_eq "MUTANT 1: the patch program succeeded" "$_m1_rc" "0"
_m1_differs=no; cmp -s "$REPO_ROOT/monitor/git-https-setup" "$_m1" || _m1_differs=yes
assert_eq "MUTANT 1: content differs from the original (APPLIED)" "$_m1_differs" "yes"
bash -n "$_m1" 2>/dev/null
assert_eq "MUTANT 1: the mutant PARSES" "$?" "0"
assert_contains "MUTANT 1: the pre-#1080 guard text is really in it" \
    "$(cat "$_m1")" '--is-inside-work-tree'

# §7a RUN-PROOF — the mutated line must SPEAK. A target with no repository
# anywhere above it is refused by the OLD guard too, so its own message
# appearing is proof that execution reached the replaced line.
_m1_live=$(bash "$_m1" --repo "$WORK/noplace/at/all" 2>&1)
assert_contains "MUTANT 1 RUN-PROOF: the mutated line executes and speaks" \
    "$_m1_live" "MUTANT-OLD-GUARD: not a git repo"

# ...and only now is this evidence rather than an absence.
_m1out=$(bash "$_m1" --repo "$WORK/enclosing/interrupted" 2>&1)
assert_not_contains "MUTANT 1: the OLD guard does NOT refuse the stub (so §3 is load-bearing)" \
    "$_m1out" "is not a git repository rooted at itself"
assert_not_contains "MUTANT 1: ...and does not refuse it via its own message either" \
    "$_m1out" "MUTANT-OLD-GUARD"
rm -f "$_m1"

# MUTANT 2 — clone-drift's old two-arm guard, restored as a standalone
# predicate and driven against the same walk-up root §4 uses.
# REACHED: the assertion reads this function's own stdout, which does not
# exist unless the mutated body ran.
_old_cd_guard() {
    if [[ ! -d "$1/.git" ]] && ! git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
        printf 'refused'; else printf 'accepted'; fi
}
assert_eq "MUTANT 2: clone-drift's OLD guard ACCEPTS a walk-up root" \
    "$(_old_cd_guard "$WORK/enclosing/plain")" "accepted"
assert_eq "MUTANT 2: ...and the fixed probe refuses the same root" \
    "$(_cd_probe "$WORK/enclosing/plain" | grep -c 'reason=not_a_git_repo')" "1"

# MUTANT 3 — install_dir_is_repo's old `[ -d "$1/.git" ]`, in BOTH directions:
# it admits what it should refuse and refuses what it should admit.
# REACHED: same — the assertions read the mutated function's own stdout.
_old_inst() { [ -d "$1/.git" ] && printf yes || printf no; }
assert_eq "MUTANT 3: the OLD install predicate ACCEPTS an interrupted-clone stub" \
    "$(_old_inst "$WORK/enclosing/interrupted")" "yes"
assert_eq "MUTANT 3: ...and REJECTS a legitimate --separate-git-dir checkout" \
    "$(_old_inst "$WORK/sepwork")" "no"

# MUTANT 4 — the template with AN operator's absolute path put back.
#
# THE SUBSTITUTED PATH IS THIS CHECKOUT'S OWN ROOT, NOT A LITERAL. Writing
# `/shared/your-lab-m/user/operator/nexus` here — which the first draft did — would
# reproduce `#1174` inside `#1174`'s own guard: on any other operator's host
# that path does not exist, the checker would answer NOT ARMED, and the final
# assertion below would fail for a reason that has nothing to do with the code
# under test. A suite that ships one operator's absolute path is the defect it
# is testing for.
# It is now the PRIMARY's root rather than `$REPO_ROOT`, for the same reason
# stated at the ARMED control above: from a secondary clone the checkout's own
# path is not what ARMED means, so `$REPO_ROOT` here would assert rc 0 about a
# configuration the tool correctly calls ARMED ELSEWHERE (rc 5).
_PRIMARY_ROOT=${_PRIMARY_BR%/monitor/boot-recover.sh}
_m4="$WORK/mutant-template.json"
sed "s#<YOUR_NEXUS_ROOT>#${_PRIMARY_ROOT}#" "$TPL" > "$_m4"
_m4_differs=no; cmp -s "$TPL" "$_m4" || _m4_differs=yes
assert_eq "MUTANT 4: content differs from the template (APPLIED)" "$_m4_differs" "yes"
python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$_m4" 2>/dev/null
assert_eq "MUTANT 4: the mutant is still valid JSON" "$?" "0"
assert_contains "MUTANT 4: the reverted template DOES carry an absolute path" \
    "$(cat "$_m4")" "$_PRIMARY_BR"
# REACHED: the mutant FILE must be shown to have been read and to have
# mattered — the checker's own output must name the substituted path. Without
# this, a checker that ignored the file entirely would satisfy the arm below.
_m4_reached=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['hooks']['SessionStart'][0]['hooks'][0]['command'])" "$_m4")
assert_eq "MUTANT 4 REACHED: the mutated file's command is the substituted path" \
    "$_m4_reached" "$_PRIMARY_BR"

_m4_settings="$WORK/mutant-settings.json"
python3 -c "import json,sys;t=json.load(open(sys.argv[1]));json.dump({'hooks':t['hooks']},open(sys.argv[2],'w'))" "$_m4" "$_m4_settings"
bash "$REPO_ROOT/monitor/boot-recover-hook-check.sh" --settings "$_m4_settings" >/dev/null 2>&1
assert_eq "MUTANT 4: on a host where that path DOES exist the checker says ARMED — which is exactly why a placeholder alone cannot protect another operator" \
    "$?" "0"

# ── §7b THE REFUSAL MUST NAME THE REPOSITORY GIT WOULD HAVE ACTED ON ────
# `inside-gitdir` and `gitdir-itself` have an EMPTY toplevel by construction,
# so the diagnostic's `[ -n "$top" ]` arm cannot fire and it used to fall
# through to "there is no repository here" — the one sentence that is FALSE
# for them, printed while `RR_GITDIR` held the exact repository. It had never
# been seen because on git >= 2.28.0 these kinds were unreachable (#1257) and
# on <= 2.23.0 nothing drove the refusal at this subject.
_rr_msg=$( . "$RR" >/dev/null 2>&1; rr_require_own_root "$WORK/bare.git/hooks/deeper/still" "t7b" 2>&1 >/dev/null )
assert_contains "§7b: refusing inside a bare repo NAMES that repo, not 'no repository here'" \
    "$_rr_msg" "$WORK/bare.git"

# ── §7c THE UNANSWERED-PROBE ARM (your-org/nexus-code#1257 skeptic F4) ───
# `#1257` introduced a third outcome for `--is-inside-work-tree`: NEITHER
# `true` nor `false`. It decides the trichotomy, so if it does not answer,
# nothing below it is entitled to decide — the arm must yield UNDETERMINED
# rather than falling into the no-work-tree branch and guessing.
#
# It shipped with no assertion, which is the same omission this file exists to
# punish: an arm nothing exercises is indistinguishable from an arm that was
# never reached. Driven with a git STUB that answers `--absolute-git-dir` (so
# the gate PASSES and we are certainly inside the classifier) and then fails
# `--is-inside-work-tree`. `_rr_git` invokes bare `git` through `env`, so a
# PATH-front stub reaches it.
_f4_dir="$WORK/f4bin"
mkdir -p "$_f4_dir"
cat > "$_f4_dir/git" <<'F4STUB'
#!/usr/bin/env bash
# minimal git stub: the gate answers, the trichotomy probe does not.
_args=("$@")
for _i in "${!_args[@]}"; do
    case "${_args[$_i]}" in
        --version)             echo "git version 2.99.0"; exit 0 ;;
        --absolute-git-dir)    echo "/f4/fake.git";       exit 0 ;;
        --is-inside-work-tree) echo "stub: refusing" >&2;  exit 128 ;;
        --git-common-dir)      echo "/f4/fake.git";       exit 0 ;;
        --is-bare-repository)  echo "true";               exit 0 ;;
        --show-toplevel)       echo "stub: refusing" >&2;  exit 128 ;;
    esac
done
exit 0
F4STUB
chmod +x "$_f4_dir/git"
_f4_line=$(PATH="$_f4_dir:$PATH" bash "$RR" "$WORK/standalone" 2>/dev/null); _f4_rc=$?
assert_eq "§7c: an UNANSWERED --is-inside-work-tree is UNDETERMINED (3), never a guess" \
    "$_f4_rc" "3"
assert_contains "§7c: …and it names WHICH probe did not answer" \
    "$_f4_line" "is_inside_work_tree_unanswered"
# POSITIVE CONTROL — the stub must not be refused for some unrelated reason.
# Without this, a stub that failed at `--version` would give the same rc 3 from
# the `git-unavailable` arm and the assertion above would pass vacuously.
assert_not_contains "§7c POSITIVE CONTROL: the stub was USABLE (not the git-unavailable arm)" \
    "$_f4_line" "git-unavailable"

# ── §8 THE PREDICATE MUST BE RIGHT ON THE GIT IT ACTUALLY RUNS ON ────────
#
# THIS SECTION EXISTS BECAUSE THIS SUITE COULD NOT FAIL ON THE HOST IT WAS
# AUTHORED ON (your-org/nexus-code#1257). Every section above drives the
# classifier under the AMBIENT git. This host's ambient git is 2.17.1; CI's is
# 2.55.0. `repo-root.sh` gated on `rev-parse --show-toplevel` returning EMPTY,
# which is a git-VERSION-scoped behaviour — rc 0 + empty at <= 2.23.0, rc 128
# + "fatal: this operation must be run in a work tree" at >= 2.28.0 — so three
# of its arms (`bare`, `gitdir-itself`, `inside-gitdir`) were dead code
# everywhere the code runs, while the suite reported 90/0 on the one machine
# where they were alive. A fix whose test only runs at 2.17.1 REPRODUCES that.
#
# So the layout table is re-driven under EVERY usable git this host offers,
# and against a table pinned LITERALLY here rather than against the ambient
# git's own answers. Comparing modern-vs-ambient would be satisfied by both
# being wrong together — this repo's "a cross-check that agrees with itself is
# not verification" rule, arriving in the instrument.
#
# The assertion COUNT is fixed at four regardless of how many gits are found,
# because the expected-count guard below is derived from this file's STRUCTURE.
_rr_gits=()          # "version|binary|libpath", usable only
_rr_seen=0           # every candidate that existed and was executable
_rr_rejected=''      # the ones that could NOT be enrolled, WITH the reason
_rr_rej_n=0          # …counted HERE, at rejection time (see the assertion below)
#
# F2 (your-org/nexus-code#1257 skeptic): AN INSTRUMENT THAT DISCOVERS ITS OWN
# MATRIX MUST PRINT WHAT IT ENROLLED — AND WHAT IT DID NOT. The first draft
# silently dropped any candidate that would not execute. On this host that is
# the two NEWEST gits (2.42.0 and 2.45.1 need `libiconv.so.2` on
# LD_LIBRARY_PATH), so the guard's real ceiling was 2.41.0 while CI runs
# 2.55.0 — a fourteen-minor blind spot, in the suite whose entire subject is a
# behaviour that changed with the git version. Assertion (1) would still have
# passed on some other candidate and reported "every usable git", so the
# narrowing was invisible by construction. That is this repo's own rule — a
# population you did not name is a population nobody can check — applied to
# the instrument rather than to the code under test.
_rr_add_git() {
    local g="${1:-}" v lib=''
    [ -n "$g" ] && [ -x "$g" ] || return 0
    _rr_seen=$(( _rr_seen + 1 ))
    # RUN IT. Trusting `-x` would enrol a binary that cannot execute and then
    # read its silence as agreement.
    v=$("$g" --version 2>/dev/null); v="${v##* }"
    if [ -z "$v" ] || case "$v" in *[!0-9.]*) true ;; *) false ;; esac; then
        # RESCUE a runtime-linkable candidate before giving up on it: try each
        # libiconv the host offers. Host-agnostic — an unmatched glob just
        # leaves the candidate rejected, with its reason recorded.
        # `find`, NOT a shell glob. AN UNMATCHED GLOB IS FATAL IN ZSH — measured,
        # `for c in /nope/*/lib` prints `no matches found` and ABORTS the shell,
        # where bash leaves the literal and the `[ -d ]` guard skips it. This
        # suite is dispatched through `$NEXUS_TEST_SHELL`, and a `zsh` dispatch
        # on a runner that has no `/app/software/libiconv` at all would kill
        # the whole suite — a suite-wide failure introduced by the fix for a
        # SILENT-NARROWING finding. `find` does the matching itself, so no
        # shell expands anything and both shells survive an absent tree.
        # CORRECTED (your-org/nexus-code#1382): this used to say "CI runs a
        # `zsh` leg". Measured at 6df5d6b9, no workflow sets
        # `NEXUS_TEST_SHELL=zsh` — `tests.yml`'s `login_shell: zsh` matrix cell
        # sets `SHELL`, the tmux pane login shell (#555), a different variable,
        # and the only `NEXUS_TEST_SHELL` assignment there is the bash-4.4
        # legacy band. The hazard is real for a LOCAL zsh dispatch (which
        # run-tests.sh now refuses, #1382) and for anyone sourcing this file
        # from zsh; it is not a CI leg.
        local cand
        while IFS= read -r cand; do
            [ -n "$cand" ] || continue
            v=$(LD_LIBRARY_PATH="$cand" "$g" --version 2>/dev/null); v="${v##* }"
            case "$v" in ''|*[!0-9.]*) v='' ;; *) lib="$cand"; break ;; esac
        done < <(find /app/software/libiconv -mindepth 2 -maxdepth 2 -type d -name lib 2>/dev/null)
    fi
    case "$v" in
        ''|*[!0-9.]*)
            _rr_rejected="$_rr_rejected ${g}(will-not-execute)"
            _rr_rej_n=$(( _rr_rej_n + 1 ))
            return 0 ;;
    esac
    _rr_gits+=("$v|$g|$lib")
}
_rr_ge_228() {       # <version> -> 0 if >= 2.28.0. No pipes: SIGPIPE lint.
    local maj min v="${1:-}"
    maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
    case "${maj}${min}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$maj" -gt 2 ] && return 0
    [ "$maj" -eq 2 ] && [ "$min" -ge 28 ]
}
_rr_add_git "$(command -v git 2>/dev/null)"
# `find`, NOT a shell glob — the SAME hazard as the libiconv loop above, and it
# survived the first fix because only one of the two was in the diff I was
# looking at. An unmatched glob is FATAL in zsh: measured here,
# `/opt/git/*/bin/git` does not exist on this host and zsh aborts the script with
# `no matches found` at this line, while bash passes the literal through and
# `_rr_add_git` skips it on `-x`. A zsh dispatch on a runner where NONE of
# these three trees exist makes the glob form a guaranteed suite-wide kill;
# `find` matches internally; nothing is expanded by the shell. (No CI leg
# dispatches this suite under zsh — see the correction at the libiconv site
# above; the belief that one did is what this comment used to state.)
while IFS= read -r _g8; do
    [ -n "$_g8" ] || continue
    _rr_add_git "$_g8"
done < <(find /app/software/git /opt/git /usr/local/git \
              -mindepth 2 -maxdepth 3 -type f -name git 2>/dev/null)
# Escape hatch for a host whose modern gits live somewhere unguessable. It can
# only ADD candidates; there is deliberately no way to switch this section off.
_rr_extra="${NEXUS_TEST_EXTRA_GITS:-}"
while [ -n "$_rr_extra" ]; do
    _rr_add_git "${_rr_extra%%:*}"
    case "$_rr_extra" in *:*) _rr_extra="${_rr_extra#*:}" ;; *) _rr_extra='' ;; esac
done

_rr_modern=''        # space-separated versions, deduped
for _e in ${_rr_gits[@]+"${_rr_gits[@]}"}; do
    _v="${_e%%|*}"
    _rr_ge_228 "$_v" || continue
    case " $_rr_modern " in *" $_v "*) continue ;; esac
    _rr_modern="$_rr_modern $_v"
done
_rr_modern="${_rr_modern# }"

# THE TABLE, PINNED. `<rc>/<kind>` per subject, relative to $WORK.
_rr_expect='bare.git=0/bare
bare.git/hooks/deeper/still=1/inside-gitdir
standalone/.git=1/gitdir-itself
standalone=0/root
enclosing/plain=1/subdir
linked-wt=1/linked-worktree
sepwork=0/root
notadir=1/none'

# _rr_table <git-bin> -> "<subject>=<rc>/<kind>" lines, in $_rr_expect's order
_rr_table() {
    local gbin="$1" libp="${2:-}" line subj got rc bindir
    bindir=$(dirname "$gbin")
    while IFS= read -r line; do
        subj="${line%%=*}"
        got=$(PATH="$bindir:$PATH" LD_LIBRARY_PATH="$libp" bash "$RR" --kind "$WORK/$subj" 2>/dev/null); rc=$?
        printf '%s=%s/%s\n' "$subj" "$rc" "$got"
    done <<<"$_rr_expect"
}

# THE ROSTER, PRINTED. Not decoration: this is the only place a reader can see
# how wide the matrix actually was, and its CEILING.
_rr_all=''
for _e in ${_rr_gits[@]+"${_rr_gits[@]}"}; do _rr_all="$_rr_all ${_e%%|*}"; done
printf '  §8 enrolled %d of %d candidate git(s):%s\n' \
    "${#_rr_gits[@]}" "$_rr_seen" "${_rr_all:- NONE}"
printf '  §8 modern (>= 2.28.0):%s\n' "${_rr_modern:- NONE}"
[ -n "$_rr_rejected" ] && printf '  §8 NOT enrolled:%s\n' "$_rr_rejected"

# (0) EVERY CANDIDATE IS ACCOUNTED FOR. enrolled + rejected must equal the
# candidates that existed, or discovery dropped one without saying so — which
# is precisely the silent narrowing F2 was filed for.
# `$_rr_rej_n` is incremented in `_rr_add_git`, NOT recovered by splitting
# `$_rr_rejected` here. ZSH DOES NOT WORD-SPLIT AN UNQUOTED PARAMETER — measured,
# `for t in $r` over a 3-word string iterates ONCE in zsh and three times in
# bash — so the split form reports 1 however many were rejected, and it reads
# correct on any host that rejects nothing (this one). A count that feeds an
# assertion must not be re-derived from a rendering of itself.
assert_eq "§8: every discovered git is accounted for — enrolled + rejected == seen (${#_rr_gits[@]} + $_rr_rej_n vs $_rr_seen)" \
    "$(( ${#_rr_gits[@]} + _rr_rej_n ))" "$_rr_seen"

# (1) A ZERO HERE WOULD BE THE DEFECT ITSELF. "No modern git found" and "modern
#     git agrees" must never look alike, so the absence is the FAILURE, not a
#     skip — the skip is the direction that let #1257 ship.
assert_eq "§8: at least one git >= 2.28.0 is available to test against (found:${_rr_modern:- NONE}; add one via NEXUS_TEST_EXTRA_GITS)" \
    "$([ -n "$_rr_modern" ] && printf yes || printf no)" "yes"

# (2) Every usable git — ambient and modern alike — must reproduce the pinned
#     table exactly. Disagreements are named, per this repo's read-the-list rule.
_rr_bad=''
for _e in ${_rr_gits[@]+"${_rr_gits[@]}"}; do
    _v="${_e%%|*}"; _b="${_e#*|}"; _b="${_b%%|*}"; _lp="${_e##*|}"
    _rr_got=$(_rr_table "$_b" "$_lp")
    [ "$_rr_got" = "$_rr_expect" ] && continue
    while IFS= read -r _line; do
        case "$_rr_expect" in *"$_line"*) continue ;; esac
        _rr_bad="$_rr_bad ${_v}:${_line}"
    done <<<"$_rr_got"
done
assert_eq "§8: every usable git classifies the layout identically (disagreements:${_rr_bad:- none})" \
    "${_rr_bad:-none}" "none"

# (3)+(4) MUTANT 5 — REVERT THE GATE PROBE TO `--show-toplevel` AND REQUIRE A
# MODERN GIT TO NOTICE. Without this, §8 is a table that happens to pass and
# nothing proves it CAN fail; with it, the section is shown to be load-bearing
# on the very host whose git cannot see the defect unaided.
# Trap-registered at the top of this file, not merely rm'd at the end: an abort
# between here and the cleanup would otherwise leave a mutated copy of the
# predicate in `monitor/` (your-org/nexus-code#1247 (c)).
_m5="$_MUT_M5"
python3 - "$RR" "$_m5" <<'MUT5'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = 'out=$(_rr_git -C "$d" rev-parse --absolute-git-dir 2>&1); rc=$?'
new = ('out=$(_rr_git -C "$d" rev-parse --show-toplevel 2>&1); rc=$?\n'
       '        inwt=$([ -n "$out" ] && printf true || printf false)')
assert old in s, "anchor missing"
open(dst, "w").write(s.replace(old, new, 1))
MUT5
_m5_ok=$?
# BOTH HALVES IN ONE VALUE. `cmp -s` against a file the patch program never
# wrote reports "differs", so a differs-only assertion says APPLIED for a
# mutant that does not exist — the anchor going stale would then be invisible
# exactly when it matters.
_m5_differs=no
[ -s "$_m5" ] && { cmp -s "$RR" "$_m5" || _m5_differs=yes; }
assert_eq "MUTANT 5: the pre-#1257 gate probe was restored (APPLIED: patch rc + content differs)" \
    "$_m5_ok/$_m5_differs" "0/yes"

# Drive the mutant under the NEWEST modern git found. A bare repository is the
# subject because `bare` is a YES verdict: at >= 2.28.0 the old gate turns it
# into `error`, so `rr_require_own_root` refuses a repository that IS its own
# root. If this assertion ever reports the mutant still answering `0/bare`, the
# git it ran under is not modern and (1) is lying.
_rr_pick=''; _rr_pick_bin=''; _rr_pick_lib=''
for _e in ${_rr_gits[@]+"${_rr_gits[@]}"}; do
    _v="${_e%%|*}"
    _rr_ge_228 "$_v" || continue
    # ANY git >= 2.28.0 exhibits the old gate's failure — the behaviour split
    # is at 2.28.0 and does not move again — so the FIRST one found is as good
    # as the newest, and picking it needs no version ordering to get wrong.
    _rr_pick="$_v"; _rr_pick_bin="${_e#*|}"; _rr_pick_bin="${_rr_pick_bin%%|*}"
    _rr_pick_lib="${_e##*|}"; break
done
_m5_kind='(no modern git)'
if [ -n "$_rr_pick_bin" ]; then
    _m5_bindir=$(dirname "$_rr_pick_bin")
    _m5_out=$(PATH="$_m5_bindir:$PATH" LD_LIBRARY_PATH="${_rr_pick_lib:-}" bash "$_m5" --kind "$WORK/bare.git" 2>/dev/null); _m5_rc=$?
    _m5_kind="$_m5_rc/$_m5_out"
fi
assert_eq "MUTANT 5 RUN-PROOF: under git $_rr_pick the OLD gate misclassifies a bare repo (so §8 can fail)" \
    "$_m5_kind" "3/error"
rm -f "$_m5"

# EXPECTED-COUNT GUARD. The total is captured BEFORE the guard counts its own
# failure; reporting `$(( PASS + FAIL ))` after `_th_fail` overstates the run
# by one and sends the next reader hunting for an assertion that never ran.
# 108 = 102 static call sites outside the §3 loop, plus the loop's 2 assertions
#       (+9 over 99 for your-org/nexus-code#1247: 1 primary-resolves control,
#        2 for (b) impostor + stderr, 1 for (b) another nexus, 2 for (a) quoted
#        path + `sh -c`, 1 for the omitted-matcher collapse found while
#        reproducing (a), and 2 new positive controls for (d)'s exemption)
# 99 = 93 static call sites outside the §3 loop, plus the loop's 2 assertions
# run over its 3 targets. (§8 contributes a FIXED four regardless of how many
# gits the host offers — see its header.) Derived from the file's STRUCTURE, not read off a
# run — a count copied from the output cannot notice an assertion that stopped
# executing, which is the only thing this guard is for. (Round 2 added 25: the
# arm-order-shadowing block, the mode-000 directory, the three-valued install
# gate, the space-in-path pair, the checker's false clearance, and two
# reached-proofs, and the refuted-sentence ratchet with its positive control.)
EXPECTED_ASSERTIONS=108
_run_total=$(( ${PASS:-0} + ${FAIL:-0} ))
if (( _run_total != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_run_total" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
