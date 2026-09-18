#!/usr/bin/env bash
# monitor/cc-harness/gate.sh — pre-update gate for Claude Code version
# bumps. Runs the real-binary harness scenarios against a CANDIDATE
# claude version installed in a throwaway prefix, returning a clean
# green/red exit BEFORE the version pin is promoted in the live clone.
#
# The scenarios drive the candidate binary against the auth-free mock
# (no Anthropic creds, no network egress) and assert that
# monitor/pane-state.sh still classifies the live panes correctly —
# i.e. that the new release didn't drift the TUI bytes the watcher
# depends on (chevron, spinner token-counter, empty-box cursor,
# AskUserQuestion chip-bar, dead-pane frame). This is exactly the class
# of breakage that has historically only surfaced in production.
#
# Usage:
#   monitor/cc-harness/gate.sh --version <npm-version>   # install + gate
#   monitor/cc-harness/gate.sh --version <v> --keep-prefix
#                                  # …and KEEP the staged install: the EXIT
#                                  # trap skips the prefix and the binary path
#                                  # is printed as `=== kept-prefix:
#                                  # claude_bin=<p> prefix=<d> ===` — export
#                                  # CLAUDE_BIN=<p> for the non-gate probes
#                                  # (2c/2d, _unstick Case A, trust arms), and
#                                  # remove <d> yourself (your-org/nexus-code#1002)
#   monitor/cc-harness/gate.sh --claude-bin <path>       # gate an existing build
#   monitor/cc-harness/gate.sh                           # gate the project-local install
#
# The candidate install is `cch_stage_candidate` (monitor/cc-harness/_lib.sh):
# `npm install --prefix <dir> --no-save …`, the ONE root-resolution-immune
# form. NEVER stage a candidate with `cd <dir> && npm install` — npm walks up
# to the nexus root's package.json and installs into the LIVE node_modules at
# rc 0 (#1002). Ad-hoc probes use the same helper, or --keep-prefix above.
#
# Exit: 0 = green (safe to promote, WITHIN the stated coverage boundary)
#       1 = red   (a scenario failed or was skipped — do NOT promote)
#       3 = UNATTRIBUTABLE (your-org/nexus-code#1259) — the gate could not
#           establish WHICH TREE it gated, so the verdict below is not a
#           claim about the candidate and must not be recorded as one.
#           A THIRD outcome on purpose: it is neither green nor red, and
#           collapsing it into either is the #1259 defect in one of its two
#           directions. Non-zero, so every caller reading `non-zero == do
#           not promote` stays correct with no change.
#       2 = usage, or REFUSED — the gate declined to render a verdict because
#           a POPULATION it depends on was empty or could not be established
#           (your-org/nexus-code#1268/#1261). A vacuous population is a
#           refusal, never a clearance: with zero scenarios the gate used to
#           print `0 passed / 0 failed / 0 skipped (of 0)` and
#           `GATE GREEN (0/0 passed) — candidate is safe to promote`, exit 0 —
#           the same green-via-nothing-ran failure this gate was written
#           against, closed for `skipped` and left open for `empty`.
#           Non-zero, so every caller reading `non-zero == do not promote`
#           stays correct with no change.
#
# Bump -> gate -> promote flow (see monitor/cc-harness/README.md):
#   1. Pick the target version (cc publishes ~daily; target latest-at-time).
#   2. gate.sh --version <ver>      # green/red against the candidate
#   3. If green: bump package.json's @anthropic-ai/claude-code pin + run
#      monitor/install-claude-local.sh in the live clone (use `npm install`,
#      NOT `npm ci`, on the NFS clone — see README), commit the pin.
#   4. Restart the watcher to load the new binary.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_self_dir/../.." && pwd)

# Shared node bootstrap (Lmod/Tcl-module HPC hosts where node lives behind
# `module load nodejs`). Both the candidate `npm install` and the
# real-binary scenarios consume node; without this the gate would skip on
# a module-based host with node off the default PATH — and a skipped
# scenario must never read as a pass (see the fail-on-skip logic below).
NEXUS_ROOT="$REPO_ROOT"
# shellcheck source=../_node-bootstrap.sh
. "$REPO_ROOT/monitor/_node-bootstrap.sh"

# The gate's POPULATION rules: the vacuous-population refusal
# (your-org/nexus-code#1268) and the derived coverage boundary
# (your-org/nexus-code#1261). See that file's header for why both live in one
# place — they are the same defect at two altitudes.
# Sourced DEFENSIVELY and its absence made an explicit refusal below, not a
# `command not found` at the call site: a gate whose population rules are
# missing has not established a population, and that must be said in those
# words rather than arriving as rc 127.
if [[ -r "$_self_dir/gate-coverage.sh" ]]; then
    # shellcheck source=gate-coverage.sh
    . "$_self_dir/gate-coverage.sh"
    _gate_population_lib=1
else
    _gate_population_lib=0
fi

# trash_path: rename-aside instead of unlink, so tearing down a throwaway
# prefix never trips on a held-open inode (`.nfs`/EBUSY over NFS).
# shellcheck source=../_trash.sh
. "$REPO_ROOT/monitor/_trash.sh"

version=""
claude_bin="${CLAUDE_BIN:-}"
keep_prefix=0
while (( $# > 0 )); do
    case "$1" in
        --version)     version="$2"; shift 2;;
        --claude-bin)  claude_bin="$2"; shift 2;;
        --keep-prefix) keep_prefix=1; shift;;
        -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) echo "gate.sh: unknown arg: $1" >&2; exit 2;;
    esac
done
# --keep-prefix names a STAGED prefix; without --version there is none, and a
# silent accept would print a kept-prefix line naming the LIVE binary — the
# exact confusion your-org/nexus-code#1002 is about. Usage error, not a no-op.
if (( keep_prefix )) && [[ -z "$version" ]]; then
    echo "gate.sh: --keep-prefix requires --version <npm-version> (there is no staged prefix to keep when gating an existing binary)" >&2
    exit 2
fi

cleanup_prefix=""
cleanup_npm_cache=""
cleanup_transcripts=""
# Move the throwaway prefix aside (rename) rather than rm — a scenario's
# claude may still be releasing files on NFS, where unlink would `.nfs`-lock
# and rm would fail. trash_path always succeeds via same-fs rename; the
# entry is reaped later by `_trash.sh --clear`. Fall back to rm if trashing
# is somehow unavailable. A throwaway npm cache we created (see below) is
# also reaped here so a gate run leaves no temp-dir litter behind.
cleanup() {
    if [[ -n "$cleanup_prefix" && -d "$cleanup_prefix" ]]; then
        if (( keep_prefix )); then
            # your-org/nexus-code#1002: the staged candidate is what the
            # non-gate probes need in hand, so it outlives this run. Said on
            # stderr at teardown so the LAST thing a reader sees names the
            # obligation it leaves behind.
            echo "gate.sh: prefix KEPT (--keep-prefix): $cleanup_prefix — candidate binary at $cleanup_prefix/node_modules/.bin/claude; remove the prefix yourself when done (trash_path, or rm -rf on a local filesystem)." >&2
        else
            trash_path "$cleanup_prefix" >/dev/null 2>&1 || rm -rf "$cleanup_prefix" 2>/dev/null || true
        fi
    fi
    if [[ -n "$cleanup_npm_cache" && -d "$cleanup_npm_cache" ]]; then
        rm -rf "$cleanup_npm_cache" 2>/dev/null || true
    fi
    if [[ -n "$cleanup_transcripts" && -d "$cleanup_transcripts" ]]; then
        rm -rf "$cleanup_transcripts" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Safety pre-flight: refuse to gate (or run any scenario) if harness code
# contains a cmdline-pattern process kill. Such a kill matches the shared
# project-local claude binary across the whole sandbox PID namespace and
# wipes every agent at once (crash postmortem 2026-05-29). Fail red before
# touching a candidate binary.
#
# The negative control runs FIRST here too, for the same reason it does for the
# tmux lint below — and specifically because what it controls is the FILE LIST.
# Both of these lints were blind to every extensionless executable in the repo
# (your-org/nexus-code#792) and not one test went red, because nothing had ever
# asserted which files get read. A guard that reports clean because it looked
# at nothing is worse than no guard.
# ---- assertion accounting (your-org/nexus-code#1019) ----------------------
#
# THE DEFECT. The gate's tally line counts SCENARIOS and never claimed
# otherwise, so evaluators reach past it for an assertion count and land on
# `grep -c '^  PASS:'` over the whole log -- which mixes two populations
# under one prefix. On the 2026-08-25 post-merge fire that produced a bare
# "108 PASS" reported as candidate coverage. It was 63 + 45: the second
# number is the two safety lints' OWN selftests, which assert their
# detectors against planted fixtures, are version-independent, and would
# pass identically against any binary. Folding them in overstated
# candidate-facing coverage by 71%.
#
# A CONVENTION WILL NOT HOLD IT, and did not: the honest split was
# disclosed on 2026-08-23 and 2026-08-25 04:19 and dropped by the next
# round -- same log, same hand-transcription. The disclosure depended on
# the evaluator remembering to decompose a number this tool handed over
# already conflated. So the tool emits both.
#
# DERIVED FROM THE PRINTED BYTES, NOT FROM A COUNTER. A running counter can
# drift from what was printed, and then the emitted number and the log
# disagree with no way to tell which is wrong. Each region's output is
# `tee`d to its own transcript as it is printed, and the counts are
# `grep -c` over those transcripts -- so the number and the log are the
# same bytes by construction.
#
# TWO TRANSCRIPTS, NOT ONE LOG PLUS AN ANCHOR. Anchoring the split on a
# line in a single log (`=== gating candidate ===`, say) is sound only
# until something is inserted; the #1259 tree stamp in this very file was
# inserted exactly there while #1019 was open. Per-region transcripts have
# no boundary to get wrong.
#
# THE FIGURES IN #1019 ARE ALREADY STALE, which is the argument for
# deriving rather than recording: measured at 989b888 the tmux-socket
# selftest emits 61 PASS lines, not the 41 the issue records, so the lint
# total is 65 and not 45. Anything hardcoded here would have shipped wrong.
#
# NAMED `gate-assertions`, NOT `assertions`. `monitor/watcher/run-tests.sh`
# already emits `=== assertions: <n> declared across ... ===`, consumed by
# `test-assertion-accounting.sh` through an anchored regex. The shapes do
# not collide today, but two differently-shaped lines under one name in one
# repo is how a future reader points the wrong parser at the wrong log.
GATE_TRANSCRIPT_DIR=$(mktemp -d -t cc-gate-transcript-XXXXXX 2>/dev/null || true)
if [[ -n "$GATE_TRANSCRIPT_DIR" && -d "$GATE_TRANSCRIPT_DIR" ]]; then
    cleanup_transcripts="$GATE_TRANSCRIPT_DIR"
    GATE_LINT_TRANSCRIPT="$GATE_TRANSCRIPT_DIR/lint.out"
    GATE_SCEN_TRANSCRIPT="$GATE_TRANSCRIPT_DIR/scenario.out"
    : > "$GATE_LINT_TRANSCRIPT"
    : > "$GATE_SCEN_TRANSCRIPT"
else
    GATE_LINT_TRANSCRIPT=""
    GATE_SCEN_TRANSCRIPT=""
fi

# _gate_count_pass <transcript> — PASS lines in a region, or `unknown`.
# `unknown` is NOT 0: a transcript we could not write is a region we could
# not count, and reporting that as zero would assert the pre-flight did not
# run when in fact we could not look. Same distinction the gate already
# draws between a skipped scenario and a passing one.
_gate_count_pass() {
    local f="$1" n
    [[ -n "$f" && -f "$f" ]] || { printf 'unknown'; return 0; }
    n=$(grep -c '^  PASS:' "$f" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
    printf '%s' "$n"
}

# _gate_run_teed <transcript> -- run "$@", streaming stdout AND appending it
# to the transcript, returning the COMMAND's status and never `tee`'s.
#
# `cmd | tee f` reports tee's status, and tee essentially always succeeds --
# the pipeline-status trap in CLAUDE.md. Here it would classify a FAILED
# safety lint as passed, i.e. it would disarm the two pre-flights that exist
# because a cmdline-pattern kill wipes every agent in the sandbox and a
# tmux server kill tears the sandbox down. PIPESTATUS[0] is read explicitly
# rather than leaning on `set -o pipefail`, so the status is right whether
# or not a future edit changes the shell options at the top of this file.
_gate_run_teed() {
    local t="$1"; shift
    if [[ -z "$t" ]]; then "$@"; return $?; fi
    "$@" | tee -a "$t"
    return "${PIPESTATUS[0]}"
}

echo "=== safety lint: no cmdline-pattern process kills in harness ==="
if ! _gate_run_teed "$GATE_LINT_TRANSCRIPT" "$_self_dir/lint-no-mass-kill.sh" --selftest; then
    echo "gate.sh: mass-kill lint FAILED ITS OWN NEGATIVE CONTROL — refusing to gate." >&2
    exit 1
fi
if ! _gate_run_teed "$GATE_LINT_TRANSCRIPT" "$_self_dir/lint-no-mass-kill.sh"; then
    echo "gate.sh: harness safety lint failed — refusing to gate." >&2
    exit 1
fi

# Second safety pre-flight, on the OTHER axis. The mass-kill lint above bounds
# the PROCESS axis; this one bounds the TMUX-SOCKET axis, where the blast
# radius is strictly worse: killing the tmux server ends the session bwrap is
# holding open, so the entire sandbox is torn down (your-org/nexus-code#644 —
# five tear-downs in 33 minutes, every worker and service lost each time).
# The negative control runs FIRST: a guard never observed failing is not
# evidence, so prove the lint still fails on planted violations before
# trusting its verdict on the real tree.
echo "=== safety lint: tmux kill-server/kill-session must be socket-scoped ==="
if ! _gate_run_teed "$GATE_LINT_TRANSCRIPT" "$_self_dir/lint-no-tmux-server-kill.sh" --selftest; then
    echo "gate.sh: tmux-socket lint FAILED ITS OWN NEGATIVE CONTROL — refusing to gate." >&2
    exit 1
fi
if ! _gate_run_teed "$GATE_LINT_TRANSCRIPT" "$_self_dir/lint-no-tmux-server-kill.sh"; then
    echo "gate.sh: tmux-socket safety lint failed — refusing to gate." >&2
    exit 1
fi

# Bring node onto PATH up front (module bootstrap on Lmod/Tcl hosts) so
# both the candidate install and the scenarios can run. Best-effort; the
# per-path checks below stay the hard gate.
nexus_ensure_node || true

# Writable npm cache for the candidate `npm install` below. npm defaults its
# cache (and, on npm 10/Node 20, its _logs) to $HOME/.npm — READ-ONLY on
# sandboxed/HPC hosts (agent-sandbox, ro-home compute nodes), where the
# install then aborts with `EROFS: read-only file system` at the first cacache
# write, before a single package is fetched (your-org/nexus-code#325; the same
# failure install-claude-local.sh already guards). Honor an operator-set
# npm_config_cache / NPM_CONFIG_CACHE; otherwise default to a throwaway cache
# under TMPDIR that the EXIT trap reaps. Unlike install-claude-local.sh's
# persistent project-local cache, the gate is a throwaway harness — a
# per-run temp cache keeps the tree clean and never collides with a parallel
# run (the `-$$` suffix is PID-unique).
if [[ -z "${npm_config_cache:-}" && -z "${NPM_CONFIG_CACHE:-}" ]]; then
    export npm_config_cache="${TMPDIR:-/tmp}/cc-gate-npm-cache-$$"
    cleanup_npm_cache="$npm_config_cache"
else
    export npm_config_cache="${npm_config_cache:-$NPM_CONFIG_CACHE}"
fi
mkdir -p "$npm_config_cache" 2>/dev/null \
    || { echo "gate.sh: cannot create npm cache dir: $npm_config_cache (set npm_config_cache/NPM_CONFIG_CACHE to a writable path)" >&2; exit 1; }

if [[ -n "$version" ]]; then
    # The install is the SHARED helper's (your-org/nexus-code#1002): the gate
    # and an ad-hoc probe stage a candidate through one root-resolution-immune
    # form, `npm install --prefix <dir> --no-save …`, and the helper refuses a
    # stage whose binary is missing or is not the candidate. Sourced HERE, on
    # the --version path only: the --claude-bin path needs nothing from
    # _lib.sh, and the classification fixtures in test-cc-gate.sh stand up a
    # gate.sh copy without it. Its absence is a REFUSAL in words, not a
    # `command not found` at the call site.
    if [[ ! -r "$_self_dir/_lib.sh" ]]; then
        echo "gate.sh: REFUSED — $_self_dir/_lib.sh is missing, so the candidate cannot be staged (cch_stage_candidate lives there)" >&2
        exit 2
    fi
    # shellcheck source=_lib.sh
    . "$_self_dir/_lib.sh"
    command -v npm >/dev/null 2>&1 || { echo "gate.sh: npm not on PATH" >&2; exit 1; }
    cleanup_prefix=$(mktemp -d -t cc-gate-prefix-XXXXXX)
    echo "=== installing @anthropic-ai/claude-code@$version into throwaway prefix ==="
    echo "    $cleanup_prefix"
    # --prefix keeps it fully out of the live tree; the live pin is
    # untouched until you choose to promote. The helper prints ONLY the
    # binary path on stdout (npm's own output goes to stderr, which the
    # gate log's `2>&1 | tee` still captures).
    if ! claude_bin=$(cch_stage_candidate "$version" "$cleanup_prefix"); then
        echo "gate.sh: candidate install failed" >&2
        exit 1
    fi
    if (( keep_prefix )); then
        # Greppable, single line, printed where the install banner is: the
        # evaluator exports CLAUDE_BIN from it for the non-gate probes.
        echo "=== kept-prefix: claude_bin=$claude_bin prefix=$cleanup_prefix ==="
    fi
fi

if [[ -z "$claude_bin" ]]; then
    claude_bin="$REPO_ROOT/node_modules/.bin/claude"
fi
[[ -x "$claude_bin" ]] || { echo "gate.sh: no executable claude at $claude_bin" >&2; exit 1; }

echo "=== gating candidate ==="
echo "    binary:  $claude_bin"
echo "    version: $("$claude_bin" --version 2>/dev/null || echo '?')"

# ---- tree attribution (your-org/nexus-code#1259) --------------------------
#
# A GATE VERDICT IS A CLAIM ABOUT (candidate x checkout), and until this
# block existed the log recorded only the candidate. The scenarios drive the
# candidate binary, but every assertion they make is made BY this checkout's
# `monitor/pane-state.sh` against this checkout's fixtures — so a red says
# "this candidate, measured by this tree", and the tree half was nowhere in
# the artefact.
#
# THE INSTANCE. 2026-09-01, candidate 2.1.252: the routine gated a clone
# whose HEAD predated the `#1214` detector fix by ninety minutes, recorded
# `block` with the reason "2.1.252 STILL omits the trust dialog's numbered
# option rows ... now 5 releases deep", and that reason was FALSE. Same
# candidate, same seven scenarios, checkout the only variable: RED 6/7 at
# `37ead52b`, GREEN 7/7 at `892674d8`. The margin was five minutes. Nothing
# downstream could disagree, because "still blocked" is what the previous
# four rounds also said -- the failure direction is an indefinite, silent
# refusal to ever bump, with a plausible reason attached each day.
#
# The stale-tree finding had to be RECONSTRUCTED after the fact from the
# primary's reflog, because `gate-2.1.252.log` cannot be attributed to a
# tree by anyone reading it. This stamp is what makes every future gate log
# self-attributing -- INCLUDING logs written before anyone thinks to check
# freshness, which is the property a freshness check in the consumer cannot
# retroactively supply.
#
# DELIBERATELY LOCAL: no `git fetch`, no `ls-remote`, no network. This block
# answers "WHICH TREE did I gate", which is knowable offline and always
# knowable. It does NOT answer "was that tree current" -- that is a
# different question, with a different subject and a different freshness
# hazard, and it belongs to the CONSUMER (`cc-auto-update-apply.sh`, which
# already owns a live-probe trichotomy in `_deployment_gate`). Answering it
# here would also be answering it about the wrong subject whenever the gate
# is run in a worktree, which is exactly how the 2026-09-01 GREEN was
# produced.
#
# THE THIRD OUTCOME. When the tree cannot be established the gate exits 3 --
# neither green (0) nor red (1). "I could not determine which tree I gated"
# must not collapse into either: as a green it licenses a bump on evidence
# about nothing, and as a red it attributes to the candidate a verdict whose
# subject is unknown. Both are the #1259 defect, one in each direction. It
# stays non-zero so every existing caller that reads `non-zero == do not
# promote` remains correct without change.
#
# `_GATE_GIT_BIN` is test-injectable, mirroring `_CLONE_DRIFT_GIT_BIN` in
# monitor/watcher/_clone_drift.sh -- the established idiom here for driving
# a git-unavailable arm without a fixture tree.
_gate_git() { "${_GATE_GIT_BIN:-git}" "$@"; }

# The artefact the scenarios actually assert THROUGH. A ref alone does not
# discriminate two trees for a reader who cannot fetch them; the blob does,
# and it is the discriminator the 2026-09-01 write-up had to reconstruct by
# hand (`08ed8ea7` stale vs `69b3d1ed` post-fix).
GATE_TREE_SUBJECT_PATH="${GATE_TREE_SUBJECT_PATH:-monitor/pane-state.sh}"

tree_unattributable=""
_gate_stamp_tree() {
    local head="" ref="" dirty="" dirty_tracked="" untracked="" blob="" why=""

    if ! command -v "${_GATE_GIT_BIN:-git}" >/dev/null 2>&1; then
        why="git_unavailable"
    elif ! _gate_git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        why="not_a_git_repo"
    else
        head=$(_gate_git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)
        [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { why="no_head"; head=""; }
    fi

    if [[ -n "$why" ]]; then
        tree_unattributable="$why"
        echo "=== gated-tree: UNATTRIBUTABLE reason=$why repo=$REPO_ROOT ==="
        echo "gate.sh: CANNOT ESTABLISH WHICH TREE I AM GATING (reason=$why)." >&2
        echo "gate.sh: the verdict below is NOT attributable to a checkout — do not" >&2
        echo "gate.sh: record it as a property of the candidate (your-org/nexus-code#1259)." >&2
        return 0
    fi

    ref=$(_gate_git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [[ -n "$ref" ]] || ref="?"
    # A DIRTY TREE IS NOT IDENTIFIED BY ITS SHA. Recorded, never refused:
    # re-gating a work-in-progress fix is a legitimate and frequent use (it
    # is what turned the 2026-09-01 verdict around), so the honest move is
    # to say so and let the consumer decide. `cc-auto-update-apply.sh`
    # refuses a dirty tree on the bump path and annotates it on the block
    # path -- two different decisions, which is precisely why this layer
    # must not make one for both.
    #
    # ---- WHICH DIRTINESS? (your-org/nexus-code#1320) --------------------
    #
    # THREE FIELDS, BECAUSE THE ONE FIELD ANSWERED A QUESTION NOBODY ASKED.
    # This block used to emit a single `dirty=` from a bare `git status
    # --porcelain`, WHICH COUNTS UNTRACKED FILES, and `cc-auto-update-apply.sh`
    # refused any bump on it. A long-lived operator clone is never free of
    # untracked files, so the two arms of `_gate_evidence_*` closed on each
    # other: evidence must come from the primary clone (or `tree-mismatch`
    # refuses it), and the primary clone can never be `dirty=0`. Measured on
    # this nexus, primary clone, `dev` @ 97c385e5 (2026-09-02) and again at
    # c055051c (2026-09-03) -- the same shape both days, so it is structural:
    #
    #     git status --porcelain --untracked-files=no | grep -c .  ->   0
    #     git status --porcelain | grep -c '^??'                   ->  21
    #
    # 21 untracked, 0 tracked -- and two of the 21 (`services.registry.lock`,
    # `services.registry.pre-headless.bak`) are written by the nexus's OWN
    # service supervisor. The bump path was not merely hard to reach; it was
    # unreachable, always, on the only tree the same function accepts
    # evidence from. It fails CLOSED, which is the safe direction and also a
    # permanent outage of the routine.
    #
    # THE PROPERTY THE REFUSAL NAMES is `does head identify what actually
    # RAN?`, and that is a question about the code the gate EXECUTED. It is
    # not the same question as `is anything at all present that git is not
    # tracking?`. So the fix is not a wider flag -- it is a narrower field
    # that measures the stated property, plus the residual kept in the record.
    #
    # WHY THE NARROWING IS SOUND -- AND THE CLAIM IS SCOPED, NOT UNIVERSAL.
    # An earlier draft of this comment claimed untracked files cannot reach
    # the gate at all. THAT IS FALSE. A second draft then claimed the reverse
    # direction universally -- "untracked can turn a green RED, never a red
    # GREEN" -- and THAT IS ALSO FALSE, measured, by the #1320 skeptic pass.
    # Both wrong versions are recorded because each is what a reader would
    # otherwise reconstruct.
    #
    # WHAT IS MEASURED, and it is the LINT CHANNEL only. The gate runs
    # `lint-no-mass-kill.sh` and `lint-no-tmux-server-kill.sh`, and BOTH
    # enumerate with `shf_find0` -- a `find` FILESYSTEM WALK, not
    # `git ls-files`. So an untracked file planted under the scanned tree IS
    # read; a planted untracked mass-kill takes the lint rc 0 -> rc 1 and it
    # names the file. In THAT channel the direction is fail-CLOSED: untracked
    # can only turn a green RED.
    #
    # THE RESIDUAL, AND IT RUNS THE OTHER WAY. `gate-coverage.sh` reads the
    # filesystem by GLOB in at least two more places, and there an untracked
    # file SATISFIES a requirement rather than violating it:
    #   - `:137`  `for a in "$hdir"/*.sh` over `monitor/harness/` feeds the
    #             delivery-transport vocabulary. An untracked adapter can
    #             satisfy the `undeclared_transport` arm at `:306`.
    #   - `:333`  `for _f in "$sdir"/test-realmodel-*.sh` feeds
    #             `gate_refuse_if_vacuous` at `:338`.
    # MEASURED: an empty scenario dir gives count=0 rc=3 REFUSED; planting ONE
    # untracked `test-realmodel-*.sh` gives count=1 rc=0 CLEARED. So an
    # untracked file CAN turn a refusal into a non-refusal. Not measured, and
    # believed on a read only: `gate_prod_scenarios` are literal paths run with
    # `bash "$s"` and nothing requires them tracked, so a committed deletion
    # plus an untracked file at the same path would execute.
    #
    # SO WHY IS KEYING THE BUMP ON `dirty_tracked` STILL RIGHT? Because that
    # residual is a property of the GATE's own coverage bookkeeping, and the
    # old `dirty=` predicate never AIMED at it -- it would have caught it only
    # incidentally, on a clone that happened to be otherwise pristine, which is
    # the case that never occurs. What `dirty_tracked` measures is the stated
    # property: does `head` identify the code that ran. A TRACKED modification
    # to a file in the executed set changes what ran without changing `head`;
    # that is what this field is for. The vacuity residual above wants its own
    # guard -- a trackedness check inside `gate-coverage.sh`'s globs -- and
    # NOT a whole-tree dirtiness proxy standing in for one.
    #
    # THE RESIDUAL, STATED. An untracked file can still matter through
    # channels this stamp does not measure: a shim shadowing something on
    # PATH, an env var, `CCH_GATE_SCENARIOS`. None of those is a property of
    # repository trackedness, and `git status --porcelain` was never their
    # guard -- it would have caught them only by accident, and only on a
    # clone that happened to be otherwise pristine. The untracked COUNT stays
    # in the record so the residual is auditable rather than invisible.
    #
    # Captured, not piped into `read`. `gate.sh` runs under `set -o pipefail`,
    # so `git status --porcelain | read` reports a CLEAN tree both when the
    # tree is clean and when git ITSELF failed -- the pipeline-status trap in
    # CLAUDE.md, in a flag whose false value is the reassuring one. Each of
    # the two statuses carries its OWN rc, and each degrades to `unknown`
    # independently: "I could not look" must not borrow the other probe`s
    # success.
    local st st_rc st_trk trk_rc
    st=$(_gate_git -C "$REPO_ROOT" status --porcelain 2>/dev/null); st_rc=$?
    if (( st_rc != 0 )); then
        dirty="unknown"
        untracked="unknown"
    else
        if [[ -n "$st" ]]; then dirty=1; else dirty=0; fi
        # `grep -c` on an empty string is 0, and a leading `??` is the
        # porcelain-v1 untracked marker. Directory-collapsed by default, so
        # this counts ENTRIES and not files -- an audit figure, and labelled
        # as one wherever it is read.
        # `|| true` is LOAD-BEARING, not decoration: `grep -c` exits 1 on a
        # count of ZERO, so on a clone with no untracked entries this line
        # returns non-zero having produced the correct answer. Harmless under
        # this file`s `set -uo pipefail`, and an abort the day anyone adds
        # `-e`. The shape check below is what actually decides the value.
        untracked=$(printf '%s\n' "$st" | grep -c '^??' || true)
        [[ "$untracked" =~ ^[0-9]+$ ]] || untracked="unknown"
    fi
    st_trk=$(_gate_git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null); trk_rc=$?
    if (( trk_rc != 0 )); then
        dirty_tracked="unknown"
    elif [[ -n "$st_trk" ]]; then
        dirty_tracked=1
    else
        dirty_tracked=0
    fi
    blob=$(_gate_git -C "$REPO_ROOT" rev-parse "HEAD:${GATE_TREE_SUBJECT_PATH}" 2>/dev/null)
    [[ "$blob" =~ ^[0-9a-f]{40}$ ]] || blob="none"

    echo "=== gated tree ==="
    echo "    repo:    $REPO_ROOT"
    echo "    head:    $head"
    echo "    ref:     $ref"
    echo "    dirty:   $dirty (any change, incl. untracked)"
    echo "    tracked: $dirty_tracked (tracked modifications only — the bump path keys on THIS)"
    echo "    untrack: $untracked (untracked porcelain entries — audit only, see #1320)"
    echo "    subject: ${GATE_TREE_SUBJECT_PATH}@$blob"
    echo "=== gated-tree: head=$head ref=$ref dirty=$dirty dirty_tracked=$dirty_tracked untracked=$untracked subject_path=${GATE_TREE_SUBJECT_PATH} subject_blob=$blob ==="
    if [[ "$dirty_tracked" == "1" ]]; then
        echo "gate.sh: NOTE — the gated tree has TRACKED modifications, so head=$head does not identify what ran." >&2
    elif [[ "$dirty_tracked" == "unknown" ]]; then
        echo "gate.sh: NOTE — could not read the tracked worktree status; dirty_tracked=unknown, so head=$head is not established as identifying." >&2
    elif [[ "$dirty" == "1" ]]; then
        echo "gate.sh: NOTE — the gated tree is clean in TRACKED files (dirty_tracked=0) but carries untracked=$untracked entries. Those are outside the executed closure (your-org/nexus-code#1320) and do not block a bump; they are recorded so the residual is auditable." >&2
    fi
}
_gate_stamp_tree

# THE PANE GEOMETRY THE SCENARIOS RUN UNDER — RESOLVED, AND STAMPED
# (your-org/nexus-code#1448).
#
# The harness has always been able to boot fullscreen: `cch_write_settings`
# emits a `tui` key whenever CCH_TUI is non-empty. Nothing in the routine's
# path ever supplied a value. `CCH_TUI` occurs in exactly two files
# repo-wide -- `.github/workflows/cc-harness.yml`, which sets it as a
# `[default, fullscreen]` matrix (the fullscreen cell exports it, the default
# cell leaves it unset), and `cc-harness/_lib.sh`, which consumes it
# -- so CI exercised both geometries while THIS gate, the one the cc-update
# routine actually runs, exercised only the binary default. Production runs
# `tui: fullscreen`, so the gate validated a geometry production does not use.
#
# Two halves, and the SECOND is the one that outlives this fix. `apply.sh`
# refuses gate evidence with no `=== gated-tree:` stamp, refuses evidence with
# no `dirty_tracked=` field, and refuses evidence past a max age -- then
# accepted it with no record of the pane geometry at all. Three demonstrations
# of attribution rigour on one axis and silence on the axis in dispute. Two
# runs known to be fullscreen only from their FILENAMES
# (`gate-2.1.246-fullscreen.log`, `gate-2.1.258-SKEPTIC-fullscreen.log`) are
# byte-indistinguishable on this axis from a default run, so no past log can
# answer the question #1448 asks. From here they can.
#
# FAIL SOFT AND LOUD. If the mode cannot be resolved, today's behaviour is
# kept -- CCH_TUI unset, binary default -- and the log SAYS SO. A guessed
# geometry would be exactly the unfalsifiable claim this issue is about.
#
# READ-ONLY, AND ONLY THE `tui` KEY. The operator's settings.json is never
# written and never echoed: it carries live credentials. `jq` extracts that one
# key, and the value is accepted only if it is a bare token matching
# `^[a-z][a-z0-9_-]{0,31}$` -- so nothing from that file can reach the log, the
# environment or a scenario argv otherwise. The same token rule is applied to a
# PRESET, for a different reason: `cch_write_settings` splices CCH_TUI into a
# JSON literal unquoted, and the stamp below must describe what that write will
# do. A preset that fails the rule is therefore REFUSED (exit 2, the gate's
# usage-error code) rather than ignored -- ignoring it would stamp
# `binary-default` while `_lib.sh` wrote the value anyway, and the stamp would
# be the one artefact in the log that is false.
_gate_resolve_tui() {
    local val="" src="" why="" f d
    local tok='^[a-z][a-z0-9_-]{0,31}$'

    # An explicit CCH_TUI wins and is never overridden: the CI matrix sets it
    # deliberately, and a resolver that clobbered it would silently collapse a
    # two-cell matrix into one.
    if [[ -n "${CCH_TUI:-}" ]]; then
        if [[ ! "$CCH_TUI" =~ $tok ]]; then
            printf 'gate.sh: REFUSED — CCH_TUI is preset to %q, which is not a bare token (%s); refusing rather than stamping a geometry the harness would not honour. Unset it or pass a value such as fullscreen.\n' "$CCH_TUI" "$tok" >&2
            exit 2
        fi
        val="$CCH_TUI"; src="preset"
    else
        why="no-settings-file"
        for d in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
            [[ -n "$d" ]] || continue
            f="$d/settings.json"
            [[ -r "$f" ]] || continue
            if ! command -v jq >/dev/null 2>&1; then
                why="jq-absent"; break
            fi
            val=$(jq -r 'if type == "object" and has("tui") then (.tui // empty) else empty end' "$f" 2>/dev/null) || val=""
            if [[ -n "$val" ]]; then
                [[ "$d" == "${CLAUDE_CONFIG_DIR:-}" ]] && src="config-dir" || src="home"
                break
            fi
            val=""; why="no-tui-key"
        done
        # THE GATE ON WHAT MAY ESCAPE THAT FILE. Anything else is discarded
        # whole -- a non-string `tui` arrives from `jq -r` as JSON text and
        # fails the same rule.
        if [[ -n "$val" && ! "$val" =~ $tok ]]; then
            val=""; src=""; why="rejected-value"
        fi
    fi

    if [[ -n "$val" ]]; then
        [[ "$src" == "preset" ]] || export CCH_TUI="$val"
        echo "=== gated-tui: mode=$val source=$src ==="
    else
        echo "=== gated-tui: mode=binary-default source=unresolved reason=$why ==="
        echo "gate.sh: NOTE — could not resolve a production TUI mode from settings.json (reason=$why); the scenarios run in the binary's own default geometry. This is the pre-#1448 behaviour, recorded rather than assumed: a green below is a claim about THAT geometry only." >&2
    fi
}
_gate_resolve_tui

# The real-binary scenarios. Add new ones here as the suite grows — AND add a
# row to monitor/cc-harness/gate-coverage.tsv, which is now enforced: a
# `test-realmodel-*.sh` on disk that is neither `gated` nor `exempt` there makes
# this gate REFUSE (exit 2) rather than quietly omitting it from the tally.
#
# Overridable via CCH_GATE_SCENARIOS (space-separated paths) for
# the gate's own classification test (monitor/watcher/test-cc-gate.sh);
# production runs never set it. The override changes what EXECUTES; it does
# not change the coverage subject (see the population block near the verdict).
#
# `gate_prod_scenarios` is built UNCONDITIONALLY and is the subject of the
# coverage boundary below, whatever CCH_GATE_SCENARIOS says. `scenarios` is
# what actually RUNS. Two names because they answer two questions, and
# collapsing them would let the override knob switch off the #1261 checks.
gate_prod_scenarios=(
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-idle-busy.sh"
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-blocked-question.sh"
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-autosuggest.sh"
        # Over-limit status + reset-time detection (2026-07-14 incident):
        # pins the StopFailure payload shape (error="rate_limit" string +
        # last_assistant_message) and the notice-text detection a CC bump
        # can silently break — both broke unnoticed before this gate entry.
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-overlimit.sh"
        # NOT GATED, BY MEASUREMENT: test-realmodel-longjob-wake.sh (the
        # longjob-watch dispatcher plugin, your-org/nexus-code#1535, GUIDE
        # surface 2g). The host arms plugin monitors only when GrowthBook
        # serves tengu_amber_sentinel=true, and under this mock backend the
        # binary is a "third-party provider" with GrowthBook OFF, so the flag
        # is its default (false) and the monitor never arms — four boots
        # measured 2026-09-15, cache seeded and telemetry re-enabled included.
        # The scenario exists, self-skips with that reason, and is an EXEMPT
        # row in gate-coverage.tsv with #1535 as owner; the real-binary wake
        # is measured by the hermetic real-auth probe recipe in GUIDE 2g.
        # PreToolUse hook contract (GUIDE surface 2d). Before this entry
        # the gate wired NO hooks outside the over-limit scenario's
        # Stop/StopFailure pair, so a changelog entry touching PreToolUse
        # could only ever be cleared by source inspection — and "partial
        # gate coverage" was credited for a different hook event. Drives a
        # real Bash tool call through a --settings-wired PreToolUse hook
        # and pins the exact fields gh-write-guard.sh / bash-footgun-guard.sh
        # parse. Carries its own negative controls (see the file header).
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-pretooluse-hook.sh"
        # Production KEYBOARD MODE (your-org/nexus-code#724). Every nexus agent
        # runs `editorMode: "vim"`; until #724 the harness seeded none, so the
        # gate validated a mode no worker is in. This list is HARDCODED, so a
        # scenario that exists but is not named here is not gated — adding the
        # file without adding this line would have reproduced #724 one level
        # down, which is the failure mode #724 is itself an instance of.
        # That hazard is now a RED rather than a comment: gate-coverage.tsv
        # ratchets the on-disk population and the gate refuses on an undeclared
        # scenario file (your-org/nexus-code#1261). It had already fired twice
        # by then — `test-realmodel-apispoof.sh` and
        # `test-realmodel-long-exchange.sh` both existed, ungated, unnamed.
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-vimode.sh"
        # The STRUCTURAL select-dialog arm (your-org/nexus-code#896). A
        # full-screen dialog used to classify `empty` — "don't know yet" — so
        # nothing unstuck a worker that would never proceed; 2.1.232 made that
        # every nested-repo spawn via the workspace-trust dialog. This is the
        # gate entry a FUTURE release's new modal trips: the arm is structural,
        # so it should keep holding, and if a repaint of the menu chrome breaks
        # it the gate says so before the pin moves. It also re-derives the
        # committed capture (`fixtures/blocked-workspace-trust-realmodel.ansi`)
        # from the live binary, which is the only thing stopping a captured
        # fixture from quietly becoming fiction.
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-trust-dialog.sh"
        # CANARY for the undocumented `CLAUDE_CODE_SANDBOXED=1` the worker
        # launchers set to keep every spawn off that same dialog
        # (your-org/nexus-code#1334). An env var read at three sites in a
        # binary re-pinned weekly: if a candidate release changes what it
        # means, this arm goes red BEFORE the pin moves, and the recovery
        # loop in spawn-worker.sh is the only thing standing until someone
        # decides. Control arm inside: key absent + env unset must still
        # paint the dialog, so a green here cannot be "the gate is gone".
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-trust-sandboxed-env.sh"
)

if [[ -n "${CCH_GATE_SCENARIOS:-}" ]]; then
    read -r -a scenarios <<< "$CCH_GATE_SCENARIOS"
    echo "=== gate-population: EXECUTED list OVERRIDDEN by CCH_GATE_SCENARIOS (${#scenarios[@]} entries); the coverage boundary below still describes the PRODUCTION list (${#gate_prod_scenarios[@]} entries) ==="
else
    scenarios=( "${gate_prod_scenarios[@]}" )
fi

# CCH_GATE=1 makes a scenario's self-skip exit 77 (the SKIP sentinel)
# instead of 0, so the gate can tell "validated and passed" apart from
# "could not validate". Under the gate a skip is a RED outcome: a skipped
# scenario means the candidate was NOT exercised, which is exactly the
# green-via-skip failure this gate exists to prevent (a prior gate printed
# GREEN with every scenario skipped for lack of node — your-org/your-nexus#236).
passed=0; failed=0; skipped=0
failed_names=(); skipped_names=()
for s in "${scenarios[@]}"; do
    echo
    echo "--- $(basename "$s") ---"
    CLAUDE_BIN="$claude_bin" RUN_CC_HARNESS=1 CCH_GATE=1 \
        _gate_run_teed "$GATE_SCEN_TRANSCRIPT" bash "$s"
    scen_rc=$?
    case "$scen_rc" in
        0)  passed=$((passed+1)) ;;
        77) echo "  >> SKIPPED: $(basename "$s") (candidate not exercised)" >&2
            skipped=$((skipped+1)); skipped_names+=("$(basename "$s")") ;;
        *)  echo "  >> FAILED: $(basename "$s") (rc=$scen_rc)" >&2
            failed=$((failed+1)); failed_names+=("$(basename "$s")") ;;
    esac
done

# RED on any failure OR any skip — a skip cannot count toward a green
# verdict (that was the bug).
rc=0
(( failed > 0 || skipped > 0 )) && rc=1

echo
echo "=== tally: ${passed} passed / ${failed} failed / ${skipped} skipped (of ${#scenarios[@]}) ==="
(( failed  > 0 )) && echo "    failed:  ${failed_names[*]}" >&2
(( skipped > 0 )) && echo "    skipped: ${skipped_names[*]} — a skip is RED (candidate not validated)" >&2

# The un-conflated assertion counts (your-org/nexus-code#1019). Quote
# `scenario=` as candidate coverage; `lint=` is the safety pre-flight's own
# selftests and says nothing about the candidate.
gate_scenario_assertions=$(_gate_count_pass "$GATE_SCEN_TRANSCRIPT")
gate_lint_assertions=$(_gate_count_pass "$GATE_LINT_TRANSCRIPT")
if [[ "$gate_scenario_assertions" =~ ^[0-9]+$ && "$gate_lint_assertions" =~ ^[0-9]+$ ]]; then
    gate_total_assertions=$(( gate_scenario_assertions + gate_lint_assertions ))
else
    gate_total_assertions="unknown"
fi
echo "=== gate-assertions: scenario=${gate_scenario_assertions} lint=${gate_lint_assertions} total=${gate_total_assertions} ==="

# A ZERO LINT COUNT IS A RED, NOT A SMALL SUITE. Both safety pre-flights
# run their own negative control first and refuse the gate if it fails --
# but a selftest that asserts NOTHING and exits 0 clears that check while
# proving nothing, which is `#792`'s "a guard that reports clean because it
# looked at nothing" in the one place whose blast radius is the whole
# sandbox. Distinguishing 0 from a small suite is the entire ask in #1019's
# second property, and it is only distinguishable because the count is now
# emitted at all.
#
# `unknown` is treated as RED too, and deliberately: it means the region
# could not be counted, and a safety pre-flight whose extent cannot be
# established has not been established to have run.
if [[ ! "$gate_lint_assertions" =~ ^[1-9][0-9]*$ ]]; then
    echo "gate.sh: SAFETY PRE-FLIGHT ASSERTED NOTHING (lint=${gate_lint_assertions}) — the two lint selftests are the negative controls for the mass-kill and tmux-server-kill guards; a vacuous pre-flight is not a pre-flight. Refusing to report this gate as green (your-org/nexus-code#1019)." >&2
    rc=1
fi

# ---- population + coverage boundary (your-org/nexus-code#1268, #1261) -----
#
# PLACED HERE, WITH THE OTHER REFUSAL FAMILIES, AND NOT BEFORE THE RUN. The
# obvious home for a population check is the top — fail before booting a real
# binary seven times. It is deliberately not there: `lint=0` and the #1259 tree
# refusal are both evaluated at this point, and every one of them destroys the
# verdict while PRESERVING the evidence printed above it. A refusal that
# short-circuits before the tally and the assertion split takes the operator's
# artefact with it, which is the same information-destroying move #1259
# explicitly rejects ("suppressing it would destroy information the operator
# needs — the fix is attribution, not silence"). An empty scenario list costs
# nothing to reach here: the loop it skipped was empty.
gate_population_refused=""

if (( _gate_population_lib == 0 )); then
    gate_population_refused="population_rules_unavailable"
    echo "=== gate-population: REFUSED reason=population_rules_unavailable path=$_self_dir/gate-coverage.sh ==="
    echo "gate.sh: REFUSED — monitor/cc-harness/gate-coverage.sh is missing, so neither the empty-population rule nor the coverage boundary could be applied." >&2
else
    # (1) THE FILED DEFECT (your-org/nexus-code#1268). Zero scenarios means
    #     nothing was measured, and `0 passed / 0 failed / 0 skipped (of 0)`
    #     followed by `GATE GREEN (0/0 passed) — candidate is safe to promote`
    #     is a clearance issued over an empty population. The subject here is
    #     the EXECUTED list, because that is what the tally above describes.
    if ! gate_refuse_if_vacuous "executed scenarios" "${#scenarios[@]}" \
            "CCH_GATE_SCENARIOS resolved to no runnable scenario; in production the list is a literal array and cannot be empty, so this is the override path."; then
        gate_population_refused="no_scenarios"
    fi

    # (2) THE COVERAGE BOUNDARY (your-org/nexus-code#1261). Computed over the
    #     PRODUCTION list, never over an override — otherwise CCH_GATE_SCENARIOS
    #     would be a way to make these checks disappear, i.e. this fix's own
    #     success path reachable without the work happening.
    if ! gcov_report "${gate_prod_scenarios[@]}"; then
        [[ -n "$gate_population_refused" ]] || gate_population_refused="coverage_boundary_unestablished"
    fi
fi

if [[ -n "$gate_population_refused" ]]; then
    echo "=== GATE REFUSED (reason=$gate_population_refused) — no verdict rendered; a vacuous or unestablished population is never a clearance ==="
    echo "gate.sh: refusing to report this run as green or red (your-org/nexus-code#1268/#1261)." >&2
    exit 2
fi

if (( rc == 0 )); then
    echo "=== GATE GREEN (${passed}/${#scenarios[@]} scenarios passed) — candidate safe to promote WITHIN the coverage boundary printed above; the 'UNCOVERED' lines are what this GREEN does NOT say ==="
else
    echo "=== GATE RED (${passed} passed / ${failed} failed / ${skipped} skipped) — do NOT promote this version ==="
fi

# THE THIRD OUTCOME (your-org/nexus-code#1259). The green/red line above is
# still printed -- suppressing it would destroy information the operator
# needs -- but it is NOT a statement about the candidate, because the
# subject of the claim was never established. Exiting 0 here would license
# a bump on evidence about an unknown tree; exiting 1 would attribute to
# the candidate a red whose cause could be the checkout. Neither is honest,
# so this is its own code, and it is LOUD.
if [[ -n "$tree_unattributable" ]]; then
    echo "=== GATE UNATTRIBUTABLE (reason=$tree_unattributable) — the verdict above is NOT a property of the candidate ==="
    echo "gate.sh: refusing to report this run as green or red: the tree it gated could not be identified (reason=$tree_unattributable)." >&2
    exit 3
fi
exit $rc
