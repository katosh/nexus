#!/usr/bin/env bash
# The automatic cc-update routine never pulls, merges, checks out, clones,
# worktrees or EXECUTES any nexus-code tree other than the live clone's own
# checked-out code — and every deploy advisory it prints names the branch it
# measured against, never a literal (your-org/nexus-code#1529).
#
# THE DIRECTIVE (operator, 2026-09-14, verbatim): "the automatic cc-update should
# never involve an automatic update of the nexus-code code. This is not
# necessary and introduces a great security risk as many people can push to
# this resource (especially not from the dev branch!)".
#
# WHAT WAS TRUE WHEN THIS LANDED. No code path pulled the clone; the exposure
# was PROSE: the GUIDE, the evaluator prompt and an apply.sh note all invited
# the autonomous evaluator to re-run the gate against the integration tip in a
# throwaway clone — unattended execution of whatever was last pushed to `dev`.
# And the deploy advisories prescribed a pull; the branch they name is the
# operator's configured integration branch, the same ref the drift is
# measured against (the first cut of this change hard-coded `main`, which on
# a dev-tracking primary is a no-op pull plus a prescribed checkout that
# regresses the running watcher — w241sk F3).
#
# WHAT IS CHECKED. Every line of the routine's population (the watcher drive,
# the evaluator and watchdog prompts, apply.sh, the gate harness, the restart
# modules, the GUIDE) is tested against four rules, and BOTH file classes —
# shell and prompt/GUIDE text — are tested by the same predicate, because the
# evaluator is an agent and text that invites the operation IS the operation:
#
#   git-verb-denied    ANY `git <verb>` whose verb is not on the READ-ONLY
#                      allowlist (rev-parse, merge-base, log, diff, show,
#                      ls-remote, fetch, cat-file, status, rev-list, …): pull,
#                      merge, rebase, reset, checkout, switch, clone, worktree,
#                      commit, stash, am — everything else. Deny is the
#                      default; the one allowed non-read-only form is the
#                      printed advisory `pull --ff-only origin <variable>`.
#   remote-blob-read   a git line carrying a `<remote-ref>:<path>` blob spec
#                      (`show origin/dev:monitor/…`, `cat-file -p
#                      FETCH_HEAD:…`): a read-only verb whose OUTPUT is
#                      remote code, red whatever the verb (w241sk D1).
#   deploy-literal-branch an advisory `pull --ff-only origin <literal>`: the
#                      deployment branch is monitor.integration_branch, the
#                      same ref the drift is measured against — never a name
#                      typed into the advisory (w241sk F3).
#   remote-tree-prose  the phrases that invited the retired control: a
#                      "fresh-tip"/"integration tip"/"throwaway clone"/"copy
#                      of the repository", "re-run the gate against …",
#                      "check out origin/…".
#   foreign-tree-exec  running cc-harness/, apply.sh or watcher/ code from a
#                      path under work/ or from a root variable outside the
#                      measured ALLOWLIST of live-clone and script-relative
#                      roots.
#
# Backslash-continued lines are joined before scanning. A whole-line comment
# in a shell or python file is skipped by the git-op arms (it cannot execute)
# and still read by the prose and exec arms.
#
# Plus presence pins: the positive rule sentence must be carried by the GUIDE,
# the prompt and apply.sh; the advisory lines (variable-branch form) must
# still exist (an advisory that vanished is drift, not compliance); and every
# file carrying an advisory names `monitor.integration_branch` as the
# operator's deployment-branch decision.
#
# WHICH DIRECTION IT ERRS IN, stated because a predicate over SOURCE TEXT for a
# RUNTIME property is an approximation. It UNDER-counts (silent-zero direction)
# a verb assembled at runtime (`git $op`, `"$g" pull`), a git binary reached
# through a variable, a helper that pulls under another name, and any
# transport of bytes into an interpreter that is not a `<remote-ref>:<path>`
# blob spec on the same line (a script written by another tool and then
# run). Continuations are joined, so a split line is no longer a gap. It OVER-counts
# a comment or doc line that spells the forbidden form out to forbid it — and
# that is the wanted direction: a loud red on a sentence is cheaper than the
# silent forms, so the rule text in the population is worded to avoid the
# spellings this guard keys on, and no marker exempts a line.
#
# THE BOUNDARY, stated because the skeptic (w241sk) measured it. This guard
# checks the TEXT the evaluator agent reads and the code the routine runs; no
# runtime mechanism refuses a git verb from the evaluator, which is spawned
# with --dangerously-skip-permissions and whose PreToolUse hook has no
# git-verb arm. Two files the evaluator also reads are NOT in the population,
# because on them the prose arm over-counts sentences that forbid the form:
# the worker floor (skills/nexus.worker-defaults/SKILL.md, rendered into the
# prompt) and CLAUDE.md (auto-loaded from the evaluator's cwd). Neither
# instructs the evaluator to pull (measured at 5055f28e).
#
# Population emptiness is REFUSED (rc 99), never reported as clean: a scan
# that read nothing cannot vouch for anything; an unreadable population file
# is REFUSED (rc 98) for the same reason. Planted violations in each file
# class prove the scan can go red; an unmodified copy proves the plants are the
# cause.
#
# Run: bash monitor/watcher/test-cc-update-no-remote-code.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)

# The routine's population: every file the automatic path READS, EXECUTES or
# RENDERS INTO A PROMPT — the watcher drive, the two prompts, the executor, the
# gate harness, the restart modules and their helpers, the GUIDE. A file that
# is not here is not checked; add it when a new path joins the routine.
NRC_NAMED=(
    monitor/watcher/_cc_auto_update.sh
    monitor/watcher/_cc_update.sh
    monitor/watcher/_clone_drift.sh
    monitor/watcher/_version_restart.sh
    monitor/cc-auto-update-apply.sh
    monitor/cc-auto-update-prompt.md
    monitor/cc-auto-update-watchdog-prompt.md
    monitor/cc-restart-watchdog-loop.sh
    monitor/cc-surface-dedup.sh
    monitor/_cc-version.sh
    monitor/_integration_branch.sh
    monitor/install-claude-local.sh
    monitor/cc-harness/README.md
    monitor/cc-harness/mock-backend.py
    skills/nexus.cc-update/GUIDE.md
)
# The EXECUTOR's own `source` lines are DERIVED into the population (bundle-2609sk
# F1): w240 made apply.sh source monitor/_tmux-window.sh, and a forbidden git
# form planted inside that helper left this guard GREEN, because the population
# was a hand list and a merge had widened the routine's code without touching
# the list. A helper the executor sources is code the routine runs; deriving it
# means the next helper apply.sh sources joins the day it is added.
#
# WHY DEPTH ONE FROM THESE FILES, AND NOT THE TRANSITIVE CLOSURE OVER THE WHOLE
# POPULATION — measured on the bundle-2609 tree: the full closure reaches 35
# files and three pre-existing helpers whose PROSE trips the text rules
# (monitor/repo-root.sh via _clone_drift.sh, monitor/watcher/_lib.sh,
# monitor/bootstrap-recover.sh via _version_restart.sh: 11 lines such as
# `'not a git repository'`), and loosening a security guard's predicate to
# admit them is not a change to make in passing. So the CLASS STAYS OPEN for a
# helper sourced by a helper; the floor below is the hand list, and this is
# the one derivation the measured hole needed.
NRC_DERIVE_FROM=(
    monitor/cc-auto-update-apply.sh
)
# _nrc_population <root> — repo-relative paths that EXIST under <root>: the
# NAMED floor, the harness directory (globbed so a new harness script joins
# automatically), then every helper a NRC_DERIVE_FROM script sources by a
# literal path suffix. Duplicates removed, order of first appearance kept.
_nrc_population() {
    local root="$1" f
    {
        for f in "${NRC_NAMED[@]}"; do [[ -f "$root/$f" ]] && printf '%s\n' "$f"; done
        for f in "$root"/monitor/cc-harness/*.sh; do
            # A test suite in the harness directory builds git fixtures; it is
            # not an automatic path. Only the harness's own scripts are
            # population.
            case "$f" in */test-*.sh) continue ;; esac
            [[ -f "$f" ]] && printf '%s\n' "${f#"$root"/}"
        done
        for f in "${NRC_DERIVE_FROM[@]}"; do [[ -f "$root/$f" ]] && _nrc_direct_sources "$root" "$f"; done
    } | awk '!seen[$0]++'
    return 0
}
# _nrc_direct_sources <root> <file> — the `.sh` files <file> SOURCES by a
# LITERAL path suffix, one per line, depth one. A `source`/`.` line's prefix
# is a variable or a `$(…)`, which in this tree means the sourcing script's
# own directory, its parent, or the repo root — so the suffix is resolved
# against those three in that order and the first EXISTING file wins (an
# over-resolution can only WIDEN the guard). WHICH DIRECTION IT ERRS IN: a
# source whose path is a bare variable (`. "$SHELL_FILES_LIB"`, `. "$init"`)
# carries no literal suffix and is SKIPPED — an under-count in the silent
# direction; name such a helper in NRC_NAMED by hand.
#
# A `source` is recognised in COMMAND POSITION anywhere on a line — line start,
# or after `;`, `&&`, `||`, `|`, `(`, `{`, `then`, `do`, `else` — so the guarded
# one-line forms are derived (sk2 F3). THE REMAINING BOUNDARIES, all in the
# silent (under-count) direction unless said otherwise:
#   * bare-variable paths — above;
#   * DEPTH ONE only: a helper sourced BY a derived helper is not followed
#     (the measured reason is at NRC_DERIVE_FROM; sk2 P-B is that boundary);
#   * a `source` whose path is split from it by a line continuation, built by
#     `eval`, or reached through a function that sources its argument;
#   * a whole-line comment is skipped; a `source …` inside a string or a
#     trailing comment on a code line IS matched — an OVER-count, which can
#     only widen the guard.
_nrc_direct_sources() {
    local _py
    _py=$(cat <<'PYEOF'
import os, re, sys
root, f = sys.argv[1], sys.argv[2]
# COMMAND POSITION, not line start (bundle-2609sk2 F3): `[[ -r X ]] && source X`
# and `if …; then . X; fi` are the commonest spelling of a guarded source in
# this tree, and `^\s*` derived neither — a helper added that way carried a
# forbidden form past this guard GREEN (sk2 P-D; its line-leading control was
# red, so the miss was the anchor and nothing else).
pat = re.compile(r'(?:^|[;&|({]|\bthen\b|\bdo\b|\belse\b)\s*(?:source|\.)\s+"?(?:\$\{?\w+\}?|\$\((?:[^()]|\([^()]*\))*\))?(/[\w./-]+\.sh)"?')
try:
    with open(os.path.join(root, f), errors='replace') as fh:
        lines = fh.read().split('\n')
except OSError:
    sys.exit(0)
d = os.path.dirname(f)
out = []
for line in lines:
    if line.lstrip().startswith('#'):
        continue
    for m in pat.finditer(line):
        suf = m.group(1).lstrip('/')
        for base in (d, os.path.join(d, '..'), '.'):
            cand = os.path.normpath(os.path.join(base, suf))
            if os.path.isfile(os.path.join(root, cand)):
                if cand not in out:
                    out.append(cand)
                break
for c in out:
    print(c)
PYEOF
)
    python3 -c "$_py" "$1" "$2"
}

# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { _nrc_population "$_repo_root" | sed "s|^|$_repo_root/|"; }
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# ---- the predicate ---------------------------------------------------------
# ERE, GNU grep. No `\b`: the word edge is spelled out so the same pattern
# reads identically under every grep this repo meets. Backslash-continued
# lines are JOINED before scanning (w241sk e7), with the ORIGINAL first line
# number kept.
#
# INVERTED AFTER THE FIRST SKEPTIC ROUND (w241sk F1): the first cut denied a
# NAMED set of hazards (a remote token, a name substring) and passed a bare
# `git pull`. Now a git verb must be on the READ-ONLY allowlist or the line is
# red; the deny arm is the default and nothing precedes it. The allowlist is
# keyed on the verb TOKEN by equality, so no safe arm can shadow the deny arm
# (CLAUDE.md, arm-order doctrine). The ONE non-read-only form allowed is the
# printed operator advisory `pull --ff-only origin <VARIABLE>` — a branch that
# is a variable or placeholder, never a literal (w241sk F3: the deployment
# branch is monitor.integration_branch, an operator decision, and measure and
# command must name the same ref).
_W='([^-A-Za-z0-9_]|$)'
# `git`, then any number of leading options, each optionally taking one
# argument (-C <dir>, -c <k=v>, -q), then the verb token.
# A path before `git` is admitted (`/usr/bin/git pull` — w241sk D1), as is an
# `--opt=value` option (`--git-dir=… pull`); a `.git/` path or `nexus-code.git`
# is still not a `git` word (the char before must not be a path/word char).
GIT_HEAD="(^|[^A-Za-z0-9_./-])([^[:space:]\"']*/)?git([[:space:]]+-[A-Za-z-]+(=[^[:space:]]*)?([[:space:]]+[^[:space:]-][^[:space:]]*)?)*[[:space:]]+"
GIT_VERB_RE="${GIT_HEAD}[A-Za-z][A-Za-z-]*"
# A read-only verb whose OUTPUT is remote code: `show origin/dev:<path> | bash`,
# `cat-file -p origin/dev:<path> > f && bash f` (w241sk D1 — the directive
# verbatim, through two allowlisted verbs). A `<remote-ref>:<path>` blob spec
# on a git line is red whatever the verb.
REMOTE_BLOB_RE='(origin/|FETCH_HEAD|refs/remotes/|@\{u(pstream)?\})[^[:space:]]*:[^[:space:]]'   # @{u}: the upstream spelling (w241sk round 3)
# A git verb spelled as a subprocess argv literal (python `subprocess.run(["git","pull"])`).
SUBPROCESS_RE="\\\\?['\"]git\\\\?['\"][[:space:]]*,[[:space:]]*\\\\?['\"][A-Za-z][A-Za-z-]*\\\\?['\"]"   # quotes may arrive backslash-escaped
READONLY_VERBS='rev-parse|merge-base|log|diff|diff-tree|show|show-ref|ls-remote|fetch|cat-file|status|rev-list|ls-files|ls-tree|for-each-ref|describe|name-rev|grep|blame|check-ignore|count-objects|version|help'
# The advisory: `pull --ff-only origin` + a shell variable, a printf `%s`, or
# a `<placeholder>` — the measured branch, never a literal name.
ALLOWED_ADVISORY_RE='pull[[:space:]]+--ff-only[[:space:]]+origin[[:space:]]+("?\$\{?[A-Za-z_][^[:space:]"]*\}?"?|%s|<[a-z][a-z-]*>)'
# …and the literal it must never be.
LITERAL_BRANCH_RE="pull[[:space:]]+--ff-only[[:space:]]+origin[[:space:]]+[a-z][A-Za-z0-9/_.-]*$_W"
PROSE_RE="fresh[- ]tip|integration tip|throwaway clone|re-?run the gate (against|in|on) |gate against (the )?(remote|integration|origin|tip)|check(ing|s)? out origin/|second gate run|copy of the repository|integration branch'?s tip|tip of the integration branch"
# Executing harness/executor/watcher code from a root that is not the live
# clone, keyed on the STRUCTURE of the path expression: the root before
# `/monitor/…` must be the live root ($NEXUS_ROOT / {{NEXUS_ROOT}}), or one of
# the script-relative roots the population resolves from its own location
# (measured at 5055f28e: these seven, all `$(dirname "${BASH_SOURCE[0]}")`-
# derived or the live root), or a bare relative path. Any other variable,
# any other template root, and any literal /work/ path is red.
EXEC_ROOT_ALLOW='NEXUS_ROOT|nexus_root|REPO_ROOT|_repo_root|_self_dir|_test_dir|monitor_dir|_monitor_dir|_gcov_repo|_cc_auto_module_dir|_VERSION_MODULE_DIR'
EXEC_RE='(/work/[^[:space:]]+|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\{\{[A-Z_]+\}\})"?(/\.\.)?/(monitor/)?(cc-harness/|cc-auto-update-apply|watcher/)'
CANDIDATE_RE="$GIT_VERB_RE|$EXEC_RE|$SUBPROCESS_RE"

# _nrc_exec_foreign <content> — rc 0 iff some harness path on the line is
# rooted at a literal /work/ path, a variable outside the allowlist, or a
# template root other than {{NEXUS_ROOT}}.
_nrc_exec_foreign() {
    local m root
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        case "$m" in
            /work/*) return 0 ;;
            '{{'*)   root="${m#\{\{}"; root="${root%%\}\}*}"; [[ "$root" == NEXUS_ROOT ]] || return 0 ;;
            *)       root="${m#\$}"; root="${root#\{}"; root="${root%%[^A-Za-z0-9_]*}"
                     grep -qE "^($EXEC_ROOT_ALLOW)$" <<<"$root" || return 0 ;;
        esac
    done <<<"$(grep -oE "$EXEC_RE" <<<"$1")"
    return 1
}

# _nrc_denied_verbs <content> — every git verb on the line that is not
# read-only, after the allowed advisory shape has been removed.
_nrc_denied_verbs() {
    local rest; rest=$(sed -E "s/$ALLOWED_ADVISORY_RE//g" <<<"$1")
    { grep -oE "$GIT_VERB_RE" <<<"$rest" | sed -E 's/.*[[:space:]]//'
      grep -oE "$SUBPROCESS_RE" <<<"$rest" | sed -E "s/.*,[[:space:]]*\\\\?['\"]//; s/\\\\?['\"]$//"; } \
      | grep -vxE "$READONLY_VERBS" | sort -u | tr '\n' ' '
}

# _nrc_classify <content> <is-shell-comment:0|1> — the FIRST rule the line
# breaks, or nothing. A whole-line COMMENT in a shell/python file cannot
# execute, so the git arms skip it; the prose and exec arms still read it.
_nrc_classify() {
    local c="$1" is_comment="${2:-0}" denied
    grep -qiE "$PROSE_RE" <<<"$c" && { echo remote-tree-prose; return; }
    _nrc_exec_foreign "$c"        && { echo foreign-tree-exec; return; }
    (( is_comment )) && return 0
    grep -qE "$LITERAL_BRANCH_RE" <<<"$c" && { echo deploy-literal-branch; return; }
    if grep -qE "$GIT_VERB_RE" <<<"$c" && grep -qE "$REMOTE_BLOB_RE" <<<"$c"; then
        echo remote-blob-read; return
    fi
    denied=$(_nrc_denied_verbs "$c")
    [[ -n "$denied" ]] && { echo "git-verb-denied(${denied% })"; return; }
    return 0
}

# _nrc_scan_file <path> <relname> — one violation per line:
#   <relname>:<lineno>:<rule>:<content>
# Continuations are joined (line number = the statement's first line);
# candidates are pre-filtered by grep (cheap); only those are classified.
_nrc_scan_file() {
    local path="$1" rel="$2" ln rule content is_comment shell=0
    case "$path" in *.sh|*.py) shell=1 ;; esac
    # The join runs ONCE into a file and its rc is read: an awk that could
    # not open the file produced NO candidates, and "no candidates" must not
    # read as "clean" (the first cut of this function passed `--` to gawk,
    # which took it as a filename, and every plant came back rc 0).
    if ! awk '{ if (buf=="") start=NR; if (sub(/\\$/,"")) { buf = buf $0 " "; next } print start "\t" buf $0; buf="" }' "$path" > "$WORK/joined.$$" 2>"$WORK/joined.err.$$"; then
        printf 'REFUSED: could not read %s: %s\n' "$rel" "$(cat "$WORK/joined.err.$$")" >&2
        : > "$WORK/refused.$$"
        rm -f "$WORK/joined.$$" "$WORK/joined.err.$$"
        return 0
    fi
    { grep -E "$CANDIDATE_RE" "$WORK/joined.$$" || true; grep -iE "$PROSE_RE" "$WORK/joined.$$" || true; } > "$WORK/cand.$$"
    sort -t$'\t' -k1,1n -u "$WORK/cand.$$" | while IFS=$'\t' read -r ln content; do
        is_comment=0
        (( shell )) && [[ "$content" =~ ^[[:space:]]*# ]] && is_comment=1
        rule=$(_nrc_classify "$content" "$is_comment")
        [[ -n "$rule" ]] && printf '%s:%s:%s:%s\n' "$rel" "$ln" "$rule" "$content"
    done
    rm -f "$WORK/cand.$$" "$WORK/joined.$$" "$WORK/joined.err.$$"
    return 0
}

# nrc_scan <root> — violations on stdout; rc 0 clean, 1 violations, 99 REFUSED
# (the population under <root> is empty — a scan that read nothing), 98
# REFUSED (a population file could not be read — a scan that read less than
# it claims; violations found in the other files are still printed).
nrc_scan() {
    local root="$1" pop f n=0
    pop=$(_nrc_population "$root")
    if [[ -z "$pop" ]]; then
        echo "REFUSED: no cc-update population under $root — nothing was scanned" >&2
        return 99
    fi
    rm -f "$WORK/refused.$$"
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        _nrc_scan_file "$root/$f" "$f"
    done <<<"$pop" > "$WORK/scan.out"
    n=$(awk 'NF{n++} END{print n+0}' "$WORK/scan.out")
    cat "$WORK/scan.out"
    if [[ -e "$WORK/refused.$$" ]]; then rm -f "$WORK/refused.$$"; return 98; fi
    (( n == 0 ))
}
_count() { awk 'NF{n++} END{print n+0}' <<<"${1:-}"; }
_rules() { awk -F: 'NF{print $3}' <<<"${1:-}" | sed -E 's/\(.*\)//' | sort -u | tr '\n' ' ' | sed 's/ $//'; }

# _fixture <name> — copy the live population under $WORK/<name>; echo the root.
_fixture() {
    local name="$1" root="$WORK/$1" f
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        mkdir -p "$root/$(dirname "$f")"; cp "$_repo_root/$f" "$root/$f"
    done <<<"$(_nrc_population "$_repo_root")"
    printf '%s' "$root"
}

RULE_PHRASE="only against the live clone's own checked-out code"

echo "=== population: named, existing, non-trivial ==="
pop=$(_nrc_population "$_repo_root"); npop=$(_count "$pop")
assert_eq "every NAMED file exists on this tree (a missing one is a rename this suite must follow)" \
    "$(for f in "${NRC_NAMED[@]}"; do [[ -f "$_repo_root/$f" ]] || printf '%s ' "$f"; done)" ""
assert_eq "the harness glob contributes at least one script" \
    "$([[ $(_count "$(grep -E '^monitor/cc-harness/.*\.sh$' <<<"$pop")") -ge 1 ]] && echo yes)" "yes"
assert_eq "the population is at least the ${#NRC_NAMED[@]} named files plus the harness" \
    "$([[ $npop -gt ${#NRC_NAMED[@]} ]] && echo yes)" "yes"

echo "=== population: the executor's sourced helpers are DERIVED, not listed (bundle-2609sk F1) ==="
assert_eq "apply.sh's sourced helpers reach the population by derivation, none by name" \
    "$(for f in monitor/_log-mode.sh monitor/_bookkeeping.sh monitor/_tmux-window.sh; do grep -qxF "$f" <<<"$pop" || printf 'missing:%s ' "$f"; grep -qxF "$f" <<<"$(printf '%s\n' "${NRC_NAMED[@]}")" && printf 'named:%s ' "$f"; done)" ""
_dr="$WORK/derive"; mkdir -p "$_dr/a" "$_dr/lib"
printf 'x=1\n' > "$_dr/lib/h.sh"
printf '_d=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)\nsource "$_d/../lib/h.sh"\n. "$SOME_LIB"\n' > "$_dr/a/x.sh"
assert_eq "derivation: a helper sourced through a directory variable and a \`..\` is found" \
    "$(_nrc_direct_sources "$_dr" a/x.sh | tr '\n' ' ')" "lib/h.sh "
assert_eq "derivation: a bare-variable source adds nothing (the stated under-count), and never errors" \
    "$(_nrc_direct_sources "$_dr" a/x.sh 2>&1 | grep -c 'SOME_LIB')" "0"
# sk2 F3: the guarded one-line forms, and a whole-line comment that must NOT count.
for _h in i j k; do printf 'x=1\n' > "$_dr/lib/$_h.sh"; done
# The two sourcing WORDS are passed as printf arguments: written inline, this suite's own text
# would carry a command-position sourcing of a path that exists nowhere, which the ambient-shell-
# option graph (aso-unresolved-sources.manifest) would have to record as an unresolvable edge.
printf '_d=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)\n[[ -r "$_d/../lib/i.sh" ]] && %s "$_d/../lib/i.sh"\nif [[ -r "$_d/../lib/j.sh" ]]; then %s "$_d/../lib/j.sh"; fi\n# then %s "$_d/../lib/k.sh"\n' source . . > "$_dr/a/y.sh"
assert_eq "derivation: a GUARDED one-line sourcing (after \`&&\`, after \`then\`) is found; a whole-line comment is not" \
    "$(_nrc_direct_sources "$_dr" a/y.sh | tr '\n' ' ')" "lib/i.sh lib/j.sh "

echo "=== the live tree: zero violations, every rule ==="
out=$(nrc_scan "$_repo_root"); rc=$?
assert_eq "live tree scan rc (violations follow if any): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-600)" "$rc" "0"

echo "=== the positive rule and the advisories are PRESENT (absence is drift, not compliance) ==="
# `grep -o … | wc -l` counts OCCURRENCES (textguard R1): two advisories on one
# line would still be two.
for f in skills/nexus.cc-update/GUIDE.md monitor/cc-auto-update-prompt.md monitor/cc-auto-update-apply.sh; do
    assert_contains "$f states the rule positively" "$(cat "$_repo_root/$f")" "$RULE_PHRASE"
done
assert_eq "_version_restart.sh's clone-drift advisory (variable branch, 1 site)" \
    "$(grep -oE "$ALLOWED_ADVISORY_RE" "$_repo_root/monitor/watcher/_version_restart.sh" | wc -l | tr -d ' ')" "1"
assert_eq "apply.sh's deployment-gate and block advisories (variable branch, 3 sites)" \
    "$(grep -oE "$ALLOWED_ADVISORY_RE" "$_repo_root/monitor/cc-auto-update-apply.sh" | wc -l | tr -d ' ')" "3"
# GUIDE sites: the evaluator-comments rule, Step 4's block wording, the Step 5
# "never conflicts" note, the Notes entry on how a fire binds.
assert_eq "the GUIDE's deploy advisories (placeholder branch, 4 sites)" \
    "$(grep -oE "$ALLOWED_ADVISORY_RE" "$_repo_root/skills/nexus.cc-update/GUIDE.md" | wc -l | tr -d ' ')" "4"
for f in monitor/watcher/_version_restart.sh monitor/cc-auto-update-apply.sh skills/nexus.cc-update/GUIDE.md monitor/cc-auto-update-prompt.md; do
    assert_contains "$f names the deployment branch as the operator's configuration (monitor.integration_branch)" \
        "$(cat "$_repo_root/$f")" "monitor.integration_branch"
done
for f in skills/nexus.cc-update/GUIDE.md monitor/cc-auto-update-prompt.md; do
    assert_contains "$f prescribes the collapsed-evidence comment format" "$(cat "$_repo_root/$f")" "<details>"
    assert_contains "$f routes re-posts through the dedup helper" "$(cat "$_repo_root/$f")" "cc-surface-dedup.sh"
done
assert_contains "the hook carries the runtime arm the text alone could not be (w241sk F2)" \
    "$(cat "$_repo_root/monitor/hooks/bash-footgun-guard.sh")" 'deliver block "cc-update-git"'

echo "=== control: an unmodified copy is clean (so the plants below are the cause) ==="
root=$(_fixture clean)
out=$(nrc_scan "$root"); rc=$?
assert_eq "unmodified copy: rc 0" "$rc" "0"
assert_eq "unmodified copy: zero lines" "$(_count "$out")" "0"

echo "=== potency, SHELL class ==="
root=$(_fixture p1)
printf '\n    git -C "$nexus_root" pull --ff-only origin dev\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "p1 rc" "$rc" "1"
assert_eq "p1: exactly one violation, in the planted file, rule named" \
    "$(awk -F: 'NF{print $1":"$3}' <<<"$out" | sort -u | tr '\n' ' ')" "monitor/watcher/_cc_auto_update.sh:deploy-literal-branch "
assert_eq "p1: one line" "$(_count "$out")" "1"
# bundle-2609sk P2: the same forbidden form inside w240's capture function in
# a helper apply.sh SOURCES. Green before the derivation (measured); red now.
root=$(_fixture ps1)
sed -i '/^tmux_selection_capture() {/a\    git pull --ff-only origin dev' "$root/monitor/_tmux-window.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "ps1: the plant took (a splice that missed would assert nothing)" \
    "$(grep -o 'git pull --ff-only origin dev' "$root/monitor/_tmux-window.sh" | wc -l)" "1"
assert_eq "ps1: a forbidden form inside a SOURCED helper is red, in that file, rule named" \
    "$rc|$(awk -F: 'NF{print $1":"$3}' <<<"$out" | sort -u | tr '\n' ' ')" "1|monitor/_tmux-window.sh:deploy-literal-branch "
# bundle-2609sk2 P-D: apply.sh gains a helper through an INLINE-CONDITIONAL
# source, and the helper carries the forbidden form. Green before the
# command-position derivation (measured by the skeptic); red now. pd2 is its
# control — the same helper behind a line-leading source — red before and after.
for _pd in pd1 pd2; do
    root=$(_fixture "$_pd")
    printf '#!/usr/bin/env bash\n_nrc_pd_helper() {\n    git pull --ff-only origin dev\n}\n' > "$root/monitor/_nrc_pd_helper.sh"
    if [[ "$_pd" == pd1 ]]; then
        sed -i '/^source "\$_self_dir\/_tmux-window.sh"/a [[ -r "$_self_dir/_nrc_pd_helper.sh" ]] \&\& source "$_self_dir/_nrc_pd_helper.sh"' "$root/monitor/cc-auto-update-apply.sh"
    else
        sed -i '/^source "\$_self_dir\/_tmux-window.sh"/a source "$_self_dir/_nrc_pd_helper.sh"' "$root/monitor/cc-auto-update-apply.sh"
    fi
    out=$(nrc_scan "$root"); rc=$?
    assert_eq "$_pd: the splice took (one new source line in the fixture's apply.sh)" \
        "$(grep -o '_nrc_pd_helper.sh' "$root/monitor/cc-auto-update-apply.sh" | wc -l)" "$([[ "$_pd" == pd1 ]] && echo 2 || echo 1)"
    assert_eq "$_pd: a forbidden form in a helper sourced $([[ "$_pd" == pd1 ]] && echo 'INLINE-CONDITIONALLY' || echo 'at line start (control)') is red, in that file, rule named" \
        "$rc|$(awk -F: 'NF{print $1":"$3}' <<<"$out" | sort -u | tr '\n' ' ')" "1|monitor/_nrc_pd_helper.sh:deploy-literal-branch "
done
root=$(_fixture p2)
printf '\n    git -C "$NEXUS_ROOT" worktree add "$tmp/tip" origin/"$branch"\n' >> "$root/monitor/cc-auto-update-apply.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "p2: a worktree add in apply.sh is a denied verb" "$rc|$(_rules "$out")|$(awk -F: 'NF{print $1}' <<<"$out" | sort -u)" "1|git-verb-denied|monitor/cc-auto-update-apply.sh"
assert_contains "p2: …and the verb is named" "$out" "git-verb-denied(worktree)"
root=$(_fixture p3)
printf '\n printf "  git -C %%s pull --ff-only origin main\\n" "$nexus_root"\n' >> "$root/monitor/watcher/_version_restart.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "p3: an advisory naming a LITERAL branch (main) is red" "$rc|$(_rules "$out")" "1|deploy-literal-branch"
root=$(_fixture p4)
printf '\n bash "$fresh_clone"/monitor/cc-harness/gate.sh --version "$candidate"\n' >> "$root/monitor/cc-harness/_lib.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "p4: the harness run from a root variable outside the allowlist" "$rc|$(_rules "$out")|$(awk -F: 'NF{print $1}' <<<"$out" | sort -u)" "1|foreign-tree-exec|monitor/cc-harness/_lib.sh"
root=$(_fixture e1)
printf '\n    git -C "$nexus_root" pull --ff-only\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "e1: a bare pull (tracked upstream) in the watcher drive is red" "$rc|$(_rules "$out")" "1|git-verb-denied"
assert_contains "e1: …naming pull" "$out" "git-verb-denied(pull)"
root=$(_fixture e2)
printf '\n    git -C "$nexus_root" pull --rebase\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "e2: pull --rebase is red" "$rc|$(_rules "$out")" "1|git-verb-denied"
root=$(_fixture e4)
printf '\n    tip=$(git -C "$nexus_root" rev-parse origin/dev)\n    git -C "$nexus_root" reset --hard "$tip"\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "e4: rev-parse passes, the reset --hard to its result is red" "$rc|$(_rules "$out")|$(_count "$out")" "1|git-verb-denied|1"
root=$(_fixture e7)
printf '\n    git -C "$nexus_root" pull --ff-only \\\n        origin dev\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "e7: a backslash-continued pull of origin dev is joined and red" "$rc|$(_rules "$out")" "1|deploy-literal-branch"
root=$(_fixture e8)
printf '\n bash "$other_root"/monitor/cc-harness/gate.sh --version "$candidate"\n' >> "$root/monitor/cc-harness/_lib.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "e8: a harness run from an unlisted root variable is red" "$rc|$(_rules "$out")" "1|foreign-tree-exec"
root=$(_fixture e10)
printf '\n    git -C "$nexus_root" stash pop\n' >> "$root/monitor/watcher/_cc_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "e10: a verb on neither list (stash) is red — deny is the default arm" "$rc|$(_rules "$out")" "1|git-verb-denied"
root=$(_fixture e11)
printf '\n    git -c advice.detachedHead=false -C "$nexus_root" checkout "$sha"\n' >> "$root/monitor/watcher/_cc_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "e11: checkout of a variable ref through -c/-C options is red" "$rc|$(_rules "$out")" "1|git-verb-denied"

echo "=== potency (w241sk D1): read-only verbs whose OUTPUT is remote code, and two regex gaps ==="
root=$(_fixture d1a)
printf '\n    git -C "$nexus_root" show origin/dev:monitor/cc-harness/gate.sh | bash -s -- --version "$c"\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "d1a: show <remote-ref>:<path> | bash is red" "$rc|$(_rules "$out")" "1|remote-blob-read"
root=$(_fixture d1b)
printf '\n    git -C "$nexus_root" cat-file -p FETCH_HEAD:monitor/cc-auto-update-apply.sh > "$tmp/apply.sh" && bash "$tmp/apply.sh" bump\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "d1b: cat-file -p FETCH_HEAD:<path> > f is red" "$rc|$(_rules "$out")" "1|remote-blob-read"
root=$(_fixture d1c)
printf '\n    /usr/bin/git -C "$nexus_root" pull --ff-only\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "d1c: an absolute-path git binary is a git word" "$rc|$(_rules "$out")" "1|git-verb-denied"
root=$(_fixture d1d)
printf '\n    git --git-dir="$nexus_root/.git" --work-tree="$nexus_root" pull --ff-only\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "d1d: --opt=value options before the verb are admitted" "$rc|$(_rules "$out")" "1|git-verb-denied"
root=$(_fixture d1e)
printf '\nsubprocess.run(["git", "pull", "--ff-only"], cwd=root)\n' >> "$root/monitor/cc-harness/mock-backend.py"
out=$(nrc_scan "$root"); rc=$?
assert_eq "d1e: a subprocess argv literal git verb is red" "$rc|$(_rules "$out")" "1|git-verb-denied"
root=$(_fixture d1g)
printf '\n    python3 -c "import subprocess; subprocess.run([\\"git\\", \\"pull\\"])"\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "d1g: …also with backslash-escaped quotes inside a python -c string" "$rc|$(_rules "$out")" "1|git-verb-denied"
root=$(_fixture d1h)
printf '\n    git -C "$nexus_root" show @{u}:monitor/cc-harness/gate.sh | bash; git -C "$nexus_root" show @{upstream}:x | sh\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "d1h: the @{u} / @{upstream} blob spelling is red (w241sk round 3)" "$rc|$(_rules "$out")" "1|remote-blob-read"
root=$(_fixture d1f)
printf '\n    git -C "$nexus_root" show HEAD:monitor/cc-harness/gate.sh | head -3; git -C "$nexus_root" diff --name-only HEAD..origin/dev\n' >> "$root/monitor/watcher/_cc_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "d1f: control — a LOCAL blob spec and a remote-ref range without a colon pass (rc 0)" "$rc" "0"

echo "=== potency, PROMPT / GUIDE / watchdog class ==="
root=$(_fixture p5)
printf '\n- If the local gate is RED, re-run the gate against the integration tip in a throwaway clone.\n' >> "$root/monitor/cc-auto-update-prompt.md"
out=$(nrc_scan "$root"); rc=$?
assert_eq "p5: the retired control re-invited in the prompt" "$rc|$(_rules "$out")|$(awk -F: 'NF{print $1}' <<<"$out" | sort -u)" "1|remote-tree-prose|monitor/cc-auto-update-prompt.md"
root=$(_fixture e9)
printf '\n- If the local gate is RED, run the harness again from a second copy of the repository at the tip of the integration branch.\n' >> "$root/monitor/cc-auto-update-prompt.md"
out=$(nrc_scan "$root"); rc=$?
assert_eq "e9: a rephrased invitation in the prompt is red" "$rc|$(_rules "$out")" "1|remote-tree-prose"
root=$(_fixture p6)
printf '\n```bash\ngit checkout origin/dev -- monitor/cc-harness\n```\n' >> "$root/skills/nexus.cc-update/GUIDE.md"
out=$(nrc_scan "$root"); rc=$?
assert_eq "p6: a checkout in a GUIDE fence is a denied verb" "$rc|$(_rules "$out")|$(awk -F: 'NF{print $1}' <<<"$out" | sort -u)" "1|git-verb-denied|skills/nexus.cc-update/GUIDE.md"
root=$(_fixture p7)
printf '\n    git clone https://github.com/your-org/nexus-code.git "$tmp/fresh"\n' >> "$root/monitor/cc-auto-update-watchdog-prompt.md"
out=$(nrc_scan "$root"); rc=$?
assert_eq "p7: a clone in the watchdog prompt is a denied verb" "$rc|$(_rules "$out")" "1|git-verb-denied"
root=$(_fixture c4)
printf '\n    git -C {{NEXUS_ROOT}} pull\n' >> "$root/monitor/cc-auto-update-prompt.md"
out=$(nrc_scan "$root"); rc=$?
assert_eq "c4: a bare pull in the prompt is red" "$rc|$(_rules "$out")" "1|git-verb-denied"
root=$(_fixture c5)
printf '\n    bash {{OTHER_ROOT}}/monitor/cc-harness/gate.sh --version {{CANDIDATE}}\n' >> "$root/monitor/cc-auto-update-prompt.md"
out=$(nrc_scan "$root"); rc=$?
assert_eq "c5: a template root other than {{NEXUS_ROOT}} before the harness is red" "$rc|$(_rules "$out")" "1|foreign-tree-exec"

echo "=== controls: what stays allowed ==="
root=$(_fixture c3)
printf '\n    # never run git -C "$nexus_root" pull from this routine\n' >> "$root/monitor/watcher/_cc_auto_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "c3: a whole-line shell comment is not a git operation (rc 0)" "$rc" "0"
root=$(_fixture a1)
printf '\n note "Deploy (monitor.integration_branch): git -C $NEXUS_ROOT pull --ff-only origin $branch"\n' >> "$root/monitor/cc-auto-update-apply.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "a1: an advisory with a VARIABLE branch is the allowed shape (rc 0)" "$rc" "0"
root=$(_fixture a1b)
printf '\nRun `git pull --ff-only origin <integration-branch>` in that clone.\n' >> "$root/skills/nexus.cc-update/GUIDE.md"
out=$(nrc_scan "$root"); rc=$?
assert_eq "a1b: a placeholder branch in GUIDE prose is allowed (rc 0)" "$rc" "0"
root=$(_fixture a2)
printf '\n note "git -C $NEXUS_ROOT pull --ff-only origin $branch; then git checkout origin/$branch"\n' >> "$root/monitor/cc-auto-update-apply.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "a2: …but a denied verb on the same line as the advisory is red" "$rc|$(_rules "$out")" "1|git-verb-denied"
root=$(_fixture a3)
printf '\n    timeout 10 git -C "$nexus_root" fetch --quiet origin "$branch"; git -C "$nexus_root" rev-parse HEAD; git -C "$nexus_root" ls-remote origin; git -C "$nexus_root" merge-base --is-ancestor a b; git -C "$nexus_root" diff --name-only HEAD..origin/dev\n' >> "$root/monitor/watcher/_cc_update.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "a3: read-only verbs (fetch, rev-parse, ls-remote, merge-base, diff) pass (rc 0)" "$rc" "0"
root=$(_fixture a4)
printf '\n bash "$NEXUS_ROOT"/monitor/cc-harness/gate.sh; bash "$_self_dir/../cc-harness/gate.sh"; bash {{NEXUS_ROOT}}/monitor/watcher/x.sh; cat .git/HEAD; echo nexus-code.git\n' >> "$root/monitor/cc-harness/_lib.sh"
out=$(nrc_scan "$root"); rc=$?
assert_eq "a4: live-root and script-relative harness paths, .git/ and .git suffixes pass (rc 0)" "$rc" "0"

echo "=== an EMPTY population is REFUSED, never green ==="
mkdir -p "$WORK/none"
out=$(nrc_scan "$WORK/none" 2>"$WORK/none.err"); rc=$?
assert_eq "empty root: rc 99" "$rc" "99"
assert_contains "empty root: the refusal says nothing was scanned" "$(cat "$WORK/none.err")" "REFUSED"
# POTENCY for the refusal: one file is enough to be a population, and then the
# verdict is a real one — here a clean one.
mkdir -p "$WORK/one/monitor/cc-harness"; printf '#!/usr/bin/env bash\necho ok\n' > "$WORK/one/monitor/cc-harness/x.sh"
out=$(nrc_scan "$WORK/one"); rc=$?
assert_eq "a one-file population is scanned, not refused" "$rc" "0"
# An UNREADABLE population file is REFUSED (98), never counted as clean —
# the failure mode the first cut of the scanner had (a broken join read as
# "no candidates").
root=$(_fixture unread)
chmod 000 "$root/monitor/cc-auto-update-prompt.md"
out=$(nrc_scan "$root" 2>"$WORK/unread.err"); rc=$?
chmod 600 "$root/monitor/cc-auto-update-prompt.md"
assert_eq "an unreadable population file: rc 98" "$rc" "98"
assert_contains "…and the refusal names the file" "$(cat "$WORK/unread.err")" "could not read monitor/cc-auto-update-prompt.md"

_EXPECTED_ASSERTIONS=71   # count=exact (summary-honesty): every assertion above, once
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
