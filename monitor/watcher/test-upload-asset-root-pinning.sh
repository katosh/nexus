#!/usr/bin/env bash
# Regression test for your-org/nexus-code#1077 — `monitor/upload-asset.sh`
# re-rooted to its OWN script location and destroyed the enclosing checkout.
#
# ---------------------------------------------------------------------------
# THE DEFECT, AS MEASURED (not as reasoned about)
# ---------------------------------------------------------------------------
#
# `upload-asset.sh` computed `_nexus_root=$(cd "$_script_dir/.." && pwd)` and
# contained ZERO references to $NEXUS_ROOT. `monitor/ng wrap-up`, run from a
# secondary clone's cwd, invokes THAT clone's copy — so the asset tree became
# `<clone>/assets`, inside a live checkout. #577 pinned reports to the primary
# and left assets unpinned; this is its residual.
#
# On its own that only misplaces the asset clone. The DESTRUCTION needs a
# second, independent fault, and the incident had it: the bootstrap probe was
#
#     [[ ! -d "$ASSETS_DIR/.git" ]]
#
# — a test for a DIRECTORY NAMED `.git`, not for a REPOSITORY. An interrupted
# asset clone leaves `<root>/assets/.git/` holding only `objects/`. That is a
# directory, so the probe concluded "already cloned" and skipped the clone; it
# is not a valid repository, so git discovery WALKED UP and every later
# `git -C "$ASSETS_DIR"` operated on the ENCLOSING repo.
#
# Observed on `work/nexus-code-stubred-sk` (a live skeptic clone) after one
# `ng wrap-up`, and reproduced byte-for-byte by case C below:
#
#     8ea077f4 HEAD@{0}: commit: Add asset ... via upload-asset.sh
#     f08fce4c HEAD@{1}: reset: moving to origin/main
#     f24c17df HEAD@{2}: checkout: moving from dev to main
#     4f1bd752 HEAD@{3}: clone: from https://github.com/your-org/nexus-code
#
# origin rewritten to the asset repo, branch dev -> main, working tree replaced,
# staged-and-unpushed work gone — and the script exited 0 and printed a valid
# URL, so the caller saw success.
#
# ---------------------------------------------------------------------------
# WHY CASE D EXISTS, AND WHY IT IS THE POINT
# ---------------------------------------------------------------------------
#
# Fixing only the root RELOCATES the destruction. With $NEXUS_ROOT honoured,
# the same `.git` stub under `<primary>/assets` retargets the PRIMARY nexus
# checkout instead of a clone's — a strictly worse outcome. Case D holds the
# root CORRECT and varies only the stub, so it fails for the pre-fix script
# even when the #1077 headline fix is applied. The guard, not the root, is what
# makes the failure impossible.
#
# ---------------------------------------------------------------------------
# Run:   bash monitor/watcher/test-upload-asset-root-pinning.sh
#        UPLOAD_ASSET_UNDER_TEST=/path/to/old/upload-asset.sh bash ...   (to
#        demonstrate every assertion FAILS on the pre-fix tree)
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy follows test-upload-asset-bootstrap.sh: a local bare repo as the
# "asset remote", stub `mint-token.sh` + `config/load.sh`, and a PATH-stubbed
# `git` that rewrites a github.com URL to the local bare. What is NEW here is
# that the fake nexus roots are themselves REAL GIT REPOSITORIES with tracked
# content and staged work — the condition none of the existing upload suites
# create, and the one under which the destruction is visible.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_test_dir/.." && pwd)
UPLOAD_UNDER_TEST="${UPLOAD_ASSET_UNDER_TEST:-$_monitor_dir/upload-asset.sh}"
[[ -f "$UPLOAD_UNDER_TEST" ]] || { echo "no such script: $UPLOAD_UNDER_TEST" >&2; exit 2; }

# Shared assertion primitives + the subshell-durable ledger. Several assertions
# below run inside `$( … )`, where a locally-counted FAIL would die with the
# child and leave the suite green — the ledger is what makes them count.
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

# `assert_ne` is not in the shared set; this suite needs it because two of its
# strongest claims are NEGATIVE (the clone's origin must NOT become the asset
# remote; the script must NOT exit 0). Routed through the shared ledger.
assert_ne() {
    local label="$1" got="$2" notwant="$3"
    if [[ "$got" != "$notwant" ]]; then
        printf '  PASS: %s\n' "$label"; _th_pass
    else
        printf '  FAIL: %s — got %q, which is exactly what must not happen\n' "$label" "$got" >&2
        _th_fail
    fi
}

REAL_GIT=$(command -v git)
[[ -x "$REAL_GIT" ]] || { echo "git not on PATH; cannot run test" >&2; exit 2; }

WORK=$(mktemp -d -t nexus-test-upload-rootpin-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

ASSET_BARE="$WORK/asset-remote.git"
NEXUS_BARE="$WORK/nexus-remote.git"

# ---- one-time remotes ----------------------------------------------------

build_remotes() {
    "$REAL_GIT" init --quiet --bare "$ASSET_BARE"
    "$REAL_GIT" --git-dir="$ASSET_BARE" symbolic-ref HEAD refs/heads/main
    local seed="$WORK/assetseed"
    "$REAL_GIT" init --quiet "$seed"
    "$REAL_GIT" -C "$seed" checkout --quiet -b main 2>/dev/null || true
    mkdir -p "$seed/assets/general"
    printf 'asset repo readme\n'  > "$seed/README.md"
    printf 'pre-existing\n'       > "$seed/assets/general/old.txt"
    "$REAL_GIT" -C "$seed" add -A
    "$REAL_GIT" -C "$seed" -c user.name=t -c user.email=t@t commit --quiet -m "asset seed"
    "$REAL_GIT" -C "$seed" push --quiet "$ASSET_BARE" main

    "$REAL_GIT" init --quiet --bare "$NEXUS_BARE"
    "$REAL_GIT" --git-dir="$NEXUS_BARE" symbolic-ref HEAD refs/heads/dev
    local seed2="$WORK/nexusseed"
    "$REAL_GIT" init --quiet "$seed2"
    "$REAL_GIT" -C "$seed2" checkout --quiet -b dev 2>/dev/null || true
    mkdir -p "$seed2/monitor" "$seed2/config"
    cp "$UPLOAD_UNDER_TEST" "$seed2/monitor/upload-asset.sh"
    chmod +x "$seed2/monitor/upload-asset.sh"
    # The shared resolver, when the script under test has one. Absent for the
    # pre-fix script, which is fine: it never looked for it.
    if [[ -f "$_monitor_dir/_nexus-root.sh" ]]; then
        cp "$_monitor_dir/_nexus-root.sh" "$seed2/monitor/_nexus-root.sh"
    fi
    cat > "$seed2/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "fake-token-for-tests"
STUB
    chmod +x "$seed2/monitor/mint-token.sh"
    # `nexus_primary_root` requires an executable <root>/monitor/ng to accept an
    # ancestor as the primary. A stub suffices — the resolver only tests -x.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$seed2/monitor/ng"
    chmod +x "$seed2/monitor/ng"
    cat > "$seed2/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.asset_repo)    printf 'fake-owner/fake-asset-repo' ;;
    github.repo)          printf 'fake-owner/fake-asset-repo' ;;
    github.bot_git_name)  printf 'test-bot[bot]' ;;
    github.bot_git_email) printf 'test-bot[bot]@users.noreply.github.com' ;;
    *)                    printf '%s' "${2-}" ;;
esac
STUB
    chmod +x "$seed2/config/load.sh"
    printf 'NEXUS-CODE SENTINEL\n' > "$seed2/SENTINEL.md"
    "$REAL_GIT" -C "$seed2" add -A
    "$REAL_GIT" -C "$seed2" -c user.name=t -c user.email=t@t commit --quiet -m "nexus seed"
    "$REAL_GIT" -C "$seed2" push --quiet "$NEXUS_BARE" dev
}

# PATH-stubbed git: rewrite any github.com URL argument to the local bare.
STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
build_git_stub() {
    cat > "$STUB_DIR/git" <<STUB
#!/usr/bin/env bash
args=("\$@")
for i in "\${!args[@]}"; do
    case "\${args[\$i]}" in
        https://*github.com/*) args[\$i]="$ASSET_BARE" ;;
    esac
done
exec "$REAL_GIT" "\${args[@]}"
STUB
    chmod +x "$STUB_DIR/git"
}

build_remotes
build_git_stub

PAYLOAD="$WORK/report.md"
printf '# a report\n' > "$PAYLOAD"

# ---- per-case fixture ----------------------------------------------------
# Builds  <case>/primary            (a nexus-code checkout, the PRIMARY)
#         <case>/primary/work/clone (a secondary clone, as #577 prescribes)
# both real git repos, the clone carrying STAGED, UNPUSHED work.
CASE_DIR=""; PRIMARY=""; CLONE=""
new_case() {
    CASE_DIR="$WORK/case-$1"
    PRIMARY="$CASE_DIR/primary"
    CLONE="$PRIMARY/work/nexus-code-task"
    mkdir -p "$CASE_DIR"
    "$REAL_GIT" clone --quiet "$NEXUS_BARE" "$PRIMARY"
    mkdir -p "$PRIMARY/work"
    "$REAL_GIT" clone --quiet "$NEXUS_BARE" "$CLONE"
    printf "worker's precious staged work\n" > "$CLONE/PRECIOUS.txt"
    "$REAL_GIT" -C "$CLONE" add PRECIOUS.txt
}

# Snapshot the five properties a destructive reset changes.
snapshot() {   # $1 = repo
    printf '%s|%s|%s|%s|%s' \
        "$("$REAL_GIT" -C "$1" rev-parse HEAD 2>&1)" \
        "$("$REAL_GIT" -C "$1" rev-parse --abbrev-ref HEAD 2>&1)" \
        "$("$REAL_GIT" -C "$1" remote get-url origin 2>&1)" \
        "$("$REAL_GIT" -C "$1" diff --cached --name-only 2>&1 | tr '\n' ',')" \
        "$("$REAL_GIT" -C "$1" reflog 2>&1 | wc -l)"
}

rc=0; stdout=""; stderr=""
run_upload() {   # $1 = cwd, $2 = script to invoke, rest = args ; env NR_ROOT
    local _cwd="$1" _script="$2"; shift 2
    local _o _e; _o=$(mktemp); _e=$(mktemp)
    if [[ -n "${NR_ROOT:-}" ]]; then
        ( cd "$_cwd" && env -u NEXUS_ASSET_REPO -u NEXUS_CONFIG \
            NEXUS_ROOT="$NR_ROOT" PATH="$STUB_DIR:$PATH" \
            "$_script" "$@" ) >"$_o" 2>"$_e"
    else
        ( cd "$_cwd" && env -u NEXUS_ASSET_REPO -u NEXUS_CONFIG -u NEXUS_ROOT \
            PATH="$STUB_DIR:$PATH" \
            "$_script" "$@" ) >"$_o" 2>"$_e"
    fi
    rc=$?
    stdout=$(<"$_o"); stderr=$(<"$_e"); rm -f "$_o" "$_e"
}

# The observed incident precondition: an interrupted asset clone leaves a
# `.git` DIRECTORY holding only `objects/`.
plant_halfclone_stub() { mkdir -p "$1/assets/.git/objects"; }

# =========================================================================
echo '=== A: $NEXUS_ROOT is honoured — a clone-cwd upload targets the PRIMARY ==='
new_case A
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --issue 1077
assert_eq       "exit 0"                                   "$rc" "0"
assert_contains "a URL is still emitted"                   "$stdout" "https://github.com/fake-owner/fake-asset-repo/"
assert_eq       "asset tree created under the PRIMARY"     "$([[ -d $PRIMARY/assets/.git ]] && echo yes || echo no)" "yes"
assert_eq       "NO asset tree created under the CLONE"    "$([[ -e $CLONE/assets ]] && echo yes || echo no)"        "no"
assert_eq       "staging/lock litter stays off the CLONE"  "$([[ -e $CLONE/assets.lock || -e $CLONE/assets.staging ]] && echo yes || echo no)" "no"

# =========================================================================
echo '=== B: $NEXUS_ROOT UNSET — the clone de-nests structurally to the primary ==='
new_case B
NR_ROOT="" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --issue 1077
assert_eq "exit 0"                                "$rc" "0"
assert_eq "asset tree under the PRIMARY"          "$([[ -d $PRIMARY/assets/.git ]] && echo yes || echo no)" "yes"
assert_eq "NO asset tree under the CLONE"         "$([[ -e $CLONE/assets ]] && echo yes || echo no)"        "no"

# =========================================================================
echo '=== C: the incident — half-created .git in the CLONE must not touch it ==='
new_case C
plant_halfclone_stub "$CLONE"
before=$(snapshot "$CLONE")
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --issue 1077
after=$(snapshot "$CLONE")
assert_eq "enclosing checkout UNCHANGED (HEAD|branch|origin|staged|reflog)" "$after" "$before"
assert_eq "tracked content survives"    "$([[ -f $CLONE/SENTINEL.md ]] && echo yes || echo no)"  "yes"
assert_eq "STAGED work survives"        "$([[ -f $CLONE/PRECIOUS.txt ]] && echo yes || echo no)" "yes"
assert_ne "clone origin NOT rewritten to the asset repo" \
          "$("$REAL_GIT" -C "$CLONE" remote get-url origin 2>&1)" "$ASSET_BARE"
assert_eq "no commit was made in the enclosing repo" \
          "$("$REAL_GIT" -C "$CLONE" log --oneline -1 --format='%s' 2>&1)" "nexus seed"

# =========================================================================
echo '=== D: root CORRECT, stub .git in the PRIMARY — must REFUSE, not reset it ==='
# This is the case the root fix alone does not cover: honouring $NEXUS_ROOT
# merely moves the same destruction onto the primary nexus checkout.
new_case D
plant_halfclone_stub "$PRIMARY"
printf "operator's staged work\n" > "$PRIMARY/OPERATOR.txt"
"$REAL_GIT" -C "$PRIMARY" add OPERATOR.txt
before=$(snapshot "$PRIMARY")
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --issue 1077
after=$(snapshot "$PRIMARY")
assert_ne       "refuses (non-zero exit)"      "$rc" "0"
assert_eq       "emits NO url"                 "$stdout" ""
assert_eq       "PRIMARY checkout UNCHANGED"   "$after" "$before"
assert_eq       "operator's staged work survives" "$([[ -f $PRIMARY/OPERATOR.txt ]] && echo yes || echo no)" "yes"
assert_contains "the refusal names the cause"  "$stderr" "not its own repository"
assert_contains "the refusal names the remedy" "$stderr" "rm -rf"

# =========================================================================
echo '=== E: fail CLOSED — an unusable $NEXUS_ROOT refuses instead of guessing ==='
new_case E
mkdir -p "$CASE_DIR/not-a-nexus"
before=$(snapshot "$CLONE")
NR_ROOT="$CASE_DIR/not-a-nexus" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --issue 1077
assert_ne       "refuses (non-zero exit)"                 "$rc" "0"
assert_eq       "emits NO url"                            "$stdout" ""
assert_eq       "did NOT silently fall back to the clone" "$([[ -e $CLONE/assets ]] && echo yes || echo no)" "no"
assert_eq       "did NOT write into the bogus root"       "$([[ -e $CASE_DIR/not-a-nexus/assets ]] && echo yes || echo no)" "no"
assert_eq       "clone untouched"                         "$(snapshot "$CLONE")" "$before"
assert_contains "the refusal says it could not establish the root" "$stderr" "cannot establish the nexus primary root"

# =========================================================================
echo '=== F: no over-refusal — a pre-existing EMPTY assets/ still bootstraps ==='
new_case F
mkdir -p "$PRIMARY/assets"
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --issue 1077
assert_eq       "exit 0"                    "$rc" "0"
assert_contains "URL emitted"               "$stdout" "https://github.com/fake-owner/fake-asset-repo/"
assert_eq       "asset tree bootstrapped"   "$([[ -d $PRIMARY/assets/.git ]] && echo yes || echo no)" "yes"

# =========================================================================
echo '=== G: a LINKED WORKTREE at assets/ is self-rooted but owns no refs — REFUSE ==='
# `git worktree add` gives `--show-toplevel` = the worktree (so a toplevel-only
# check calls it self-rooted) while `--absolute-git-dir` points into the PARENT
# repo. `reset --hard` there moves the PARENT's branch: #1077's outcome by a
# second road. Measured on this host; the guard tests BOTH.
new_case G
"$REAL_GIT" -C "$PRIMARY" worktree add --detach "$PRIMARY/assets" HEAD >/dev/null 2>&1
before=$(snapshot "$PRIMARY")
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --issue 1077
assert_ne       "refuses (non-zero exit)"        "$rc" "0"
assert_eq       "emits NO url"                   "$stdout" ""
assert_eq       "the PARENT repo is UNCHANGED"   "$(snapshot "$PRIMARY")" "$before"
assert_contains "the refusal names the ref store" "$stderr" "LINKED WORKTREE"

# =========================================================================
echo '=== H: a REFUSAL is ATOMIC — it must not leave a request a later upload adopts ==='
# The guard's own data-loss mode (skeptic finding 2). STAGE runs BEFORE the
# guard, and a later upload's batch manager snapshots `"$STAGING_DIR"/*.req` and
# commits EVERY marker it finds. So a refused payload could be committed, to a
# live path, by an unrelated upload — while its caller had been told rc=4 and
# the header had told it nothing was touched.
#
# The assertion is deliberately end-to-end rather than "no .req file remains":
# the file is the mechanism, the OUTCOME is what matters, and only the outcome
# distinguishes a clean refusal from a deferred one.
new_case H
plant_halfclone_stub "$PRIMARY"
printf 'PAYLOAD FROM THE REFUSED UPLOAD\n' > "$WORK/refused.md"
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$WORK/refused.md" \
    --repo-path assets/general/old.txt          # aimed at a path the asset repo already holds
assert_ne "the upload is refused" "$rc" "0"
assert_eq "nothing of ours is left staged" \
    "$(ls "$PRIMARY"/assets.staging/*.req "$PRIMARY"/assets.staging/*.blob 2>/dev/null | wc -l)" "0"

# The operator clears the debris; an unrelated upload of a different file runs.
rm -rf "$PRIMARY/assets"
printf 'a totally unrelated figure\n' > "$WORK/unrelated.png"
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$WORK/unrelated.png" \
    --repo-path assets/general/fig.png
assert_eq "the unrelated upload succeeds" "$rc" "0"
assert_eq "the refused payload did NOT reach the live path" \
    "$("$REAL_GIT" --git-dir="$ASSET_BARE" show main:assets/general/old.txt 2>&1)" "pre-existing"
assert_eq "the unrelated upload committed ONLY its own file" \
    "$("$REAL_GIT" --git-dir="$ASSET_BARE" log --oneline main 2>&1 | grep -c 'refused\.md')" "0"

# =========================================================================
# ==== your-org/nexus-code#1173: WHICH REMOTE, not which tree =============
#
# Cases A-H all ask which local TREE git acts on. Five bot commits reached the
# shared implementation repo's `main` with every one of those guards passing,
# because `remote set-url origin` REPOINTS a perfectly self-rooted asset clone
# at whatever `$REPO` says. The fixture below is therefore the mirror image of
# theirs: the asset tree is healthy throughout and only the DESTINATION varies.
#
# The primary's origin is repointed at a github.com URL so the derived rule has
# something to derive from — the real primary's origin IS the implementation
# repo, which is the whole shape of the defect.
_NEXUS_REPO=fake-owner/fake-nexus-code
_ASSET_REPO=fake-owner/fake-asset-repo
_pin_origin() { "$REAL_GIT" -C "$1" remote set-url origin "https://github.com/$_NEXUS_REPO.git"; }

echo '=== I: --repo naming the nexus code repo is REFUSED (the flag-collision arm) ==='
new_case I
_pin_origin "$PRIMARY"
before=$(snapshot "$PRIMARY")
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --repo "$_NEXUS_REPO"
assert_eq       "refuses with the destination code (7)"   "$rc" "7"
assert_eq       "emits NO url"                            "$stdout" ""
assert_eq       "no asset tree was even created"          "$([[ -e $PRIMARY/assets ]] && echo yes || echo no)" "no"
assert_eq       "the nexus checkout is UNCHANGED"         "$(snapshot "$PRIMARY")" "$before"
assert_contains "the refusal names the two meanings of --repo" "$stderr" "means the ISSUE repo"
# THE ARM ONLY RULE 1 PROTECTS, and the reason it is asserted separately: a
# THIRD repo — an external one the worker's issue happens to live on — is not
# this checkout's origin, so rule 2 cannot see it, and the asset would be
# pushed into somebody else's repository. Without this, dropping rule 1 costs
# exactly one message assertion and looks nearly harmless.
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --repo other-org/someone-elses-repo
assert_eq "--repo naming a THIRD repo is refused too (rule 2 cannot see it)" "$rc" "7"
assert_eq "…and nothing was pushed anywhere"                                 "$stdout" ""

echo '=== J: the same destination via --asset-repo and via the env is REFUSED too ==='
# Rule 1 is about a FLAG NAME; rule 2 is about the DESTINATION, so it must hold
# whatever supplied it — otherwise the fix is a spelling rule, not a guard.
new_case J
_pin_origin "$PRIMARY"
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --asset-repo "$_NEXUS_REPO"
assert_eq       "--asset-repo <own origin> refuses (7)"  "$rc" "7"
assert_contains "…naming the checkout's own origin"      "$stderr" "OWN origin"
_j_o=$(mktemp); _j_e=$(mktemp)
( cd "$CLONE" && env -u NEXUS_CONFIG NEXUS_ROOT="$PRIMARY" NEXUS_ASSET_REPO="$_NEXUS_REPO" \
    PATH="$STUB_DIR:$PATH" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" ) >"$_j_o" 2>"$_j_e"
_j_rc=$?
assert_eq "NEXUS_ASSET_REPO=<own origin> refuses (7) as well" "$_j_rc" "7"
assert_eq "…and emits no url"                                "$(cat "$_j_o")" ""
rm -f "$_j_o" "$_j_e"

echo '=== K: NO OVER-REFUSAL — the correct destination still uploads, by every route ==='
# The failure mode of a destination guard is refusing the good path, which
# would take the whole asset surface down; every report in this workspace
# reaches its issue through here.
new_case K
_pin_origin "$PRIMARY"
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --issue 1173
assert_eq       "default (no flag) still uploads"        "$rc" "0"
assert_contains "…and emits the asset repo's URL"        "$stdout" "https://github.com/$_ASSET_REPO/"
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --repo "$_ASSET_REPO" --issue 1173
assert_eq       "--repo RESTATING the configured asset repo is a no-op, not a refusal" "$rc" "0"
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --asset-repo "$_ASSET_REPO" --issue 1173
assert_eq       "--asset-repo naming the asset repo works"  "$rc" "0"

echo '=== L: a 7 is ATOMIC, and an unreadable origin SAYS so rather than passing quietly ==='
new_case L
_pin_origin "$PRIMARY"
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --repo "$_NEXUS_REPO"
assert_eq "a refused destination stages NOTHING" \
    "$(ls "$PRIMARY"/assets.staging/*.req "$PRIMARY"/assets.staging/*.blob 2>/dev/null | wc -l)" "0"
# Origin removed: the rule cannot be evaluated. It must not silently pass — a
# silence that means "could not check" reads as "checked and fine", which is
# this workspace's dominant defect class.
"$REAL_GIT" -C "$PRIMARY" remote remove origin
NR_ROOT="$PRIMARY" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --issue 1173
assert_eq       "an unreadable origin does not block a correct upload" "$rc" "0"
assert_contains "…but it SAYS the guard did not evaluate"              "$stderr" "self-push guard did not evaluate"

echo '=== M: #1077 pinned WHICH SCRIPT; this pins WHICH TREE IT ANSWERS ABOUT ==='
# `config/load.sh:48` is `nexus_root="${NEXUS_ROOT:-$(cd "$script_dir/.." && pwd)}"`
# — the ENVIRONMENT wins over the script's own location. So resolving `$_cfg` to
# the PRIMARY's copy is not enough: invoked with $NEXUS_ROOT still pointing at a
# clone, the PRIMARY's own load.sh reads the CLONE's config. The fixture makes
# the two configs DISAGREE, which is the only way this assertion can fail.
new_case M
_pin_origin "$PRIMARY"
# BOTH load.sh copies are replaced by a stub that honours $NEXUS_ROOT THE WAY
# THE REAL ONE DOES (load.sh:48) — reading the answer out of
# ${NEXUS_ROOT:-<own root>}/config/asset-repo.txt. Without that the fixture
# cannot express the defect at all: the plain stub ignores the environment, so
# un-pinning the read changes nothing and the case is vacuous. It was, once.
for _r in "$PRIMARY" "$CLONE"; do
    cat > "$_r/config/load.sh" <<'ENVCFG'
#!/usr/bin/env bash
_sd=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_root="${NEXUS_ROOT:-$(cd "$_sd/.." && pwd)}"
case "${1:-}" in
    github.asset_repo|github.repo) cat "$_root/config/asset-repo.txt" ;;
    github.bot_git_name)           printf 'test-bot[bot]' ;;
    github.bot_git_email)          printf 'test-bot[bot]@users.noreply.github.com' ;;
    *)                             printf '%s' "${2-}" ;;
esac
ENVCFG
    chmod +x "$_r/config/load.sh"
done
printf '%s' "$_ASSET_REPO"                  > "$PRIMARY/config/asset-repo.txt"
printf '%s' 'wrong-owner/CLONE-CONFIG-READ' > "$CLONE/config/asset-repo.txt"
NR_ROOT="$CLONE" run_upload "$CLONE" "$CLONE/monitor/upload-asset.sh" "$PAYLOAD" --issue 1173
assert_eq       "exit 0"                                     "$rc" "0"
assert_contains "the URL names the PRIMARY's asset repo"     "$stdout" "https://github.com/$_ASSET_REPO/"
assert_eq       "…and NOT the clone's config"                "${stdout##*CLONE-CONFIG-READ*}" "$stdout"

# =========================================================================
# ASSERTION-COUNT GUARD (count=exact). An EXACT comparison, not a floor: this
# suite's whole value is a set of specific claims, and a claim that silently
# stops executing is indistinguishable from one that passes. Six cases, in
# order: 5 + 3 + 5 + 6 + 6 + 3 + 4 + 5, then #1173's I-M: 7 + 4 + 4 + 3 + 3.
EXPECTED_ASSERTIONS=58
_ran=$(( ${PASS:-0} + ${FAIL:-0} ))
if (( _ran != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$_ran" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
