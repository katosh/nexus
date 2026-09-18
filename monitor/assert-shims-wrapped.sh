#!/usr/bin/env bash
# monitor/assert-shims-wrapped.sh — spawn-time precondition for EVERY
# PATH-front shim this nexus ships, plus an OBSERVED check that the worker's
# RLIMIT_NPROC ceiling really reaches the processes it is supposed to bound.
# Called by every agent-spawning launcher AFTER it sources locals-env.sh and
# AFTER it applies its `ulimit -Su` line, and BEFORE it exec's claude. On a
# confirmed failure it refuses (non-zero) so the launcher aborts and the agent
# never starts — fail-CLOSED.
#
# HISTORY / WHY THIS IS NOT `gh`-SPECIFIC (your-org/nexus-code#589).
# The first version of this guard (assert-gh-wrapped.sh, #578) checked exactly
# one shim: monitor/ghwrap/gh. But the PATH root cause it guards — an rc that
# re-prepends linuxbrew AFTER the nexus fronted its toolchain, burying every
# wrapper at once — is not `gh`-specific. It defeats EVERY PATH-front shim
# simultaneously, and the others fail in the opposite, worse direction:
#
#   * `gh` unwrapped is fail-SAFE BY ACCIDENT. locals-env scopes the ambient
#     GH_CONFIG_DIR to a credential-free dir, so an unwrapped `gh <write>`
#     errors ("please run gh auth login") instead of posting as the operator.
#   * `pip` unwrapped is fail-OPEN. monitor/pipwrap/pip exists because the
#     agent-sandbox /app/bin/pip re-execs itself without bound: on 2026-07-09 a
#     single `pip download` reached 10,242 processes, exhausted the node's
#     pid_max, and killed the watcher plus nine of twelve workers
#     (your-org/nexus-code#487). A bare `pip` that MISSES the shim simply RUNS,
#     and the blast radius is every user on a shared node.
#
# Worse, the guard's existence hides the risk: the worker floor tells agents the
# shim "is the enforcement", so an agent has positive grounds to believe the
# hazard is handled. A silently-inapplicable enforcement mechanism is more
# dangerous than a documented hazard.
#
# ENUMERATED, NEVER HAND-MAINTAINED. The required shim set is discovered by
# GLOBBING the shim directories ($NEXUS_ROOT/monitor/*wrap) and listing the
# executables inside them — it is never a literal list in this file. That is a
# direct response to the failure mode: what broke was a mechanism that existed
# and silently stopped applying, and a hand-maintained list of "shims to check"
# reproduces exactly that class (add monitor/foowrap, forget to add it here, and
# the new guard is unenforced from birth). Drop a shim dir in and it is required
# automatically.
#
# RLIMIT_NPROC IS CHECKED BY OBSERVATION, NOT BY READING THE LAUNCHER. When a
# shim IS bypassed, the soft RLIMIT_NPROC ceiling is the only remaining layer
# between one runaway worker and the node (#487). Its correctness must therefore
# not be inferred from the launcher containing a `ulimit` line — note that line
# is written `ulimit -Su N 2>/dev/null || true`, so a failure to apply it is
# SWALLOWED. This helper measures the live soft limit in its own process, in a
# spawned CHILD (bash subshell), and in a GRANDCHILD (nested subshell, plus a
# `python` subprocess where available), and refuses when the ceiling is missing
# or fails to propagate.
#
# FAIL-CLOSED, DELIBERATELY SCOPED. This helper gates EVERY agent spawn, so a
# false refusal would halt the whole nexus. It therefore refuses ONLY on a
# CONFIRMED-bad observation: a guarded name resolving to a real binary that is
# NOT the shim, an alias/function shadowing a guarded name ahead of the shim, or
# a ceiling that demonstrably failed to apply or propagate. States it cannot
# adjudicate — a name that does not resolve at all (a missing command fails
# loudly on use), python absent — do NOT refuse: they degrade to a loud WARNING
# and allow the spawn.
#
# THE THIRD OUTCOME, exit 79 (your-org/nexus-code#612). Three states are not
# adjudications at all: the guard never got as far as examining its subject.
# NEXUS_ROOT unset, no shim dirs anywhere to enumerate, and a probe shell that
# does not exist. Those used to `exit 0` — "the check did not run" and "the
# check ran and was clean" were the SAME observable value, which is the entire
# defect class this file exists to close, reproduced inside the file itself. 79
# still ALLOWS the spawn (see the fail-closed scoping above): the caller decides.
# monitor/guard-block.sh.in records it as NOT CHECKED in the durable
# guard-unverified.log and proceeds, and refuses (78) under
# NEXUS_REQUIRE_SHIM_CHECK.
#
# WHERE THE 79 BOUND IS DRAWN, and on which axis. The axis is NOT "did anything
# go unobserved" — it is **could the guard examine its subject at all**. On the
# 79 side: no root, no shim dirs, no probe shell — nothing was examined, and no
# statement about this host's shims is available. On the 0-plus-WARNING side:
# the guard DID examine its subject and reached a judgement about an individual
# item — a guarded name that resolves to nothing (a missing command fails loudly
# on use, so it is safe), an unenforceable bash `-lic` surface (the CARVE-OUT),
# an nproc leg it could not read (no python, unreadable limit). Those are
# adjudications, so they are not 79.
#
# The DECLARED RESIDUAL, on the same axis: the explicit caller opt-outs
# NEXUS_ASSERT_SKIP_SHIMS=1 and NEXUS_ASSERT_SKIP_NPROC=1 do NOT produce 79
# either, and that is a deliberate line rather than an oversight. 79 exists so
# that a check which silently failed to run cannot pass for a check that ran;
# a caller that set the skip flag itself already knows which leg it disabled.
# No in-tree launcher sets either flag (asserted by this file's suite) — they
# are test affordances. If a launcher ever does set one, that boundary needs
# redrawing, and the assertion is what will say so.
#
# Exit codes:
#   0  CHECKED. Every discovered shim reachable in every enforceable surface,
#      and the nproc ceiling observed to apply and propagate. Per-item warnings
#      and the bash `-lic` carve-out live here: the guard looked and judged.
#      THREE surfaces are examined, not two (your-org/nexus-code#652, #654):
#      the AMBIENT one — the PATH this guard was handed by its caller — plus
#      the two spawned probe shells. The ambient one was added because the two
#      spawned ones cannot see the caller: a session replaying a PATH snapshot
#      frozen before a PATH fix keeps the pre-fix ordering for its whole life,
#      while every shell this guard spawns re-derives the fixed ordering. The
#      guard therefore used to reach a CONFIDENT WRONG ANSWER — exit 0 in a
#      worker whose own `command -v pip` answered `/app/bin/pip`, the #487
#      fork-storm binary. All of #612's hardening is on the COULD-NOT-LOOK
#      axis and none of it helps against looking at the wrong thing.
#   1  CONFIRMED failure. The launcher must abort the spawn.
#  79  NOT CHECKED — the guard's own precondition is absent (NEXUS_ROOT unset,
#      no shim dirs, probe shell missing). Never folded into 0. A CONFIRMED
#      failure outranks it: if any leg refuses, the verdict is 1, because
#      "part of this could not be checked and part of it FAILED" is a failure.
#
# Overrides (for tests):
#   NEXUS_SHIMWRAP_GLOB       shim-dir glob (default $NEXUS_ROOT/monitor/*wrap)
#   NEXUS_ASSERT_GH_SHELL     shell to probe (default $SHELL, then /usr/bin/zsh)
#   NEXUS_INHERITED_PATH      the PATH THIS PROCESS WAS GIVEN, recorded by
#                             monitor/shellenv/bash_env.sh before it re-fronts.
#                             Read (never written) here; it is what the AMBIENT
#                             surface adjudicates. Absent → falls back to $PATH,
#                             which is the weaker reading and is documented as
#                             such at the surface itself.
#   NEXUS_ASSERT_NPROC_EXPECT expected soft RLIMIT_NPROC (the launcher's
#                             ceiling). Unset/0 → propagation is still observed,
#                             but no specific ceiling is required.
#   NEXUS_ASSERT_SKIP_NPROC=1 skip the nproc observation entirely.
#   NEXUS_ASSERT_SKIP_SNAPSHOT=1 skip the frozen-snapshot leg entirely.
#   NEXUS_ASSERT_SNAPSHOT     read THIS snapshot file instead of discovering one.
#   NEXUS_ASSERT_NO_ANCESTRY=1 disable the ancestry walk, forcing the mtime
#                             proxy — a test seam, so the two selection routes
#                             can be exercised independently.
#   NEXUS_CC_HOME             when set, the ONLY Claude-Code home consulted for
#                             snapshots. A fixture overriding HOME does not
#                             necessarily override CLAUDE_CONFIG_DIR, so without
#                             an exclusive seam this leg reads the REAL host's
#                             snapshot from inside a synthetic fixture.
#   NEXUS_SPAWNER_SNAPSHOT    the snapshot the SPAWNING agent's own tool shell
#                             sources, carried into the launcher by
#                             spawn-worker.sh (your-org/nexus-code#1477). Ranked
#                             after this process's own ancestry and BEFORE the
#                             newest-by-mtime proxies: it is a nexus-launched
#                             artifact on the same rc chain as the child, which
#                             is the subject the snapshot leg's header always
#                             claimed to examine. Scoped by NEXUS_CC_HOME like
#                             the ancestry route: a path outside that home is
#                             ignored, not preferred.
#   NEXUS_ASSERT_SKIP_SHIMS=1 skip the shim-reachability probes entirely.
#   NEXUS_ASSERT_PROBE_TIMEOUT     seconds a probe shell may run before SIGTERM
#                             (default 40); NEXUS_ASSERT_PROBE_KILL_GRACE seconds
#                             after that before SIGKILL (default 5). Probe shells
#                             run DETACHED from the controlling tty (`setsid`,
#                             stdin </dev/null) — see `_asw_probe_exec` for the
#                             measured hang this closes. Test seams for the kill
#                             path; leave at the defaults in production.
#
# Inputs that are NOT overrides — contracts other launchers already pin:
#   NEXUS_IS_ORCHESTRATOR=1   exported by EVERY orchestrator spawn path
#                             (monitor/watcher/_respawn.sh's launcher, and
#                             spawn-fresh-orchestrator.sh through it; asserted
#                             by test-respawn.sh, test-spawn-fresh-orchestrator.sh
#                             and test-target-config.sh). It marks the SELF-HEAL
#                             path: on it the frozen-snapshot leg below WARNS and
#                             records durably but never refuses
#                             (your-org/nexus-code#1477 — see that leg for the
#                             stated error direction). Worker spawns do not set
#                             it and keep the fail-CLOSED refusal.

set -u

_asw_say() { printf 'assert-shims-wrapped: %s\n' "$*" >&2; }

_asw_tmp="${TMPDIR:-/tmp}/.nexus-asw.$$"
trap 'rm -f "$_asw_tmp" "$_asw_tmp".probe 2>/dev/null || true' EXIT

# The THIRD OUTCOME accumulator. Every "the guard could not examine its
# subject" state records itself here and execution CONTINUES, so that a leg
# which CAN still be observed (nproc does not need NEXUS_ROOT or a probe shell)
# is not skipped by an early exit — an early `exit 79` would mask a confirmed
# failure discovered further down, turning a refusal into an allow.
_asw_notchecked=0
_asw_not_checked() {
    _asw_notchecked=1
    _asw_say "NOT CHECKED: $1"
}

_asw_root="${NEXUS_ROOT:-}"
if [ -z "$_asw_root" ]; then
    # No NEXUS_ROOT means locals-env never ran — the launcher is malformed. Not
    # an identity-leak or fork-storm state on its own (there is no scoped config
    # and no fronted PATH either), but it IS a broken spawn, and the shim dirs
    # cannot be located at all, so nothing about them is verified.
    # Unconditional, and deliberately NOT softened when NEXUS_SHIMWRAP_GLOB
    # happens to supply a location: an unset root means locals-env never ran,
    # so the PATH front whose survival this guard exists to verify was never
    # applied in the first place. Whether a glob can still be enumerated is
    # beside the point — there is no vouched-for spawn environment here.
    _asw_not_checked "NEXUS_ROOT unset — locals-env never ran, so the PATH front this guard verifies was never applied (malformed launcher env)."
fi

# realpath helper: prefer `readlink -f`, fall back to dirname-cd + basename.
# Same shape the shims themselves use (ghwrap/gh's `_gw_rp`, pipwrap/pip's
# `_pw_rp`), so a shim dir reachable under a second name (a symlink, a bind
# mount, /shared/... vs its automount alias) compares equal here too.
_asw_rp() {
    if readlink -f / >/dev/null 2>&1; then
        readlink -f "$1" 2>/dev/null && return 0
    fi
    _asw_rp_d=$(CDPATH= cd "$(dirname "$1")" 2>/dev/null && pwd) || return 1
    printf '%s/%s\n' "$_asw_rp_d" "$(basename "$1")"
}

# ---------------------------------------------------------------------------
# Discover the shim set: every executable in every shim dir.
# ---------------------------------------------------------------------------
# With no root and no explicit override there is nowhere to look — leave the
# glob EMPTY rather than letting it degrade to the literal `/monitor/*wrap`,
# which would put a nonsense path into the operator-facing message.
if [ -n "${NEXUS_SHIMWRAP_GLOB:-}" ]; then
    _asw_glob="$NEXUS_SHIMWRAP_GLOB"
elif [ -n "$_asw_root" ]; then
    _asw_glob="$_asw_root/monitor/*wrap"
else
    _asw_glob=""
fi
_asw_dirs=""     # newline-separated: each shim dir, plus its realpath
_asw_names=""    # newline-separated: guarded command names, de-duplicated
# NEXUS_GHWRAP_DIR is the pre-#589 override (it named the single expected
# wrapper dir). Honour it as an ADDITIONAL shim dir so a fork or an old caller
# that sets it keeps getting a real check instead of silently falling through to
# "no shim dirs found".
for _asw_d in $_asw_glob ${NEXUS_GHWRAP_DIR:+"$NEXUS_GHWRAP_DIR"}; do
    [ -d "$_asw_d" ] || continue
    _asw_has=0
    for _asw_f in "$_asw_d"/*; do
        # Include symlinks (monitor/pipwrap/pip3 -> pip): the shim resolves the
        # invoked NAME, so `pip3` must be guarded in its own right.
        { [ -f "$_asw_f" ] || [ -L "$_asw_f" ]; } && [ -x "$_asw_f" ] || continue
        _asw_has=1
        _asw_n=$(basename -- "$_asw_f")
        case "
${_asw_names}" in
            *"
${_asw_n}
"*) : ;;
            *) _asw_names="${_asw_names}${_asw_n}
" ;;
        esac
    done
    [ "$_asw_has" = 1 ] || continue
    _asw_dirs="${_asw_dirs}${_asw_d}
"
    _asw_dr=$(_asw_rp "$_asw_d" 2>/dev/null || true)
    if [ -n "$_asw_dr" ] && [ "$_asw_dr" != "$_asw_d" ]; then
        _asw_dirs="${_asw_dirs}${_asw_dr}
"
    fi
done

_asw_have_shims=0
[ -n "$_asw_names" ] && _asw_have_shims=1

# Is `$1` a path under one of the shim dirs? Fed by here-doc (NOT a pipeline)
# so `return` acts on this function, not on a subshell.
_asw_under_shim() {
    _asw_p="${1:-}"
    [ -n "$_asw_p" ] || return 1
    _asw_pr=$(_asw_rp "$_asw_p" 2>/dev/null || true)
    while IFS= read -r _asw_cd; do
        [ -n "$_asw_cd" ] || continue
        case "$_asw_p" in "$_asw_cd"/*) return 0 ;; esac
        if [ -n "$_asw_pr" ]; then
            case "$_asw_pr" in "$_asw_cd"/*) return 0 ;; esac
        fi
    done <<EOF
${_asw_dirs}
EOF
    return 1
}

# ---------------------------------------------------------------------------
# THE AMBIENT SURFACE (your-org/nexus-code#652, #654)
# ---------------------------------------------------------------------------
# The two probe surfaces below spawn a FRESH `$SHELL`. This guard's own
# process does not, and that difference is the whole of #652/#654: an agent's
# Bash tool call is not a fresh shell, it is
#
#     /usr/bin/zsh -c source ~/.claude/.../snapshot-zsh-<id>.sh …
#
# replaying a PATH captured ONCE at session start. A session that started
# before a PATH fix keeps the pre-fix ordering for its whole life, and every
# freshly spawned probe shell reports the FIXED ordering — so the guard
# reached a CONFIDENT WRONG ANSWER by measuring the wrong shell. Both halves
# were measured in one worker seconds apart: `command -v pip` -> /app/bin/pip
# (the #487 fork-storm binary) while this guard exited 0.
#
# MEASURED, this host, 44 snapshots on disk at 2026-09-02T08:40Z (the count
# GROWS as sessions start — it was 52 an hour later, so it is pinned to its
# moment rather than quoted bare):
#
#   position 13   13 snapshots   2026-08-04 06:34 .. 2026-08-05 07:48
#   position  2    1 snapshot    2026-08-06 04:32          <- the transition
#   position  1   30 snapshots   2026-08-08 04:24 onward
#
# THE MIDDLE ROW IS STATED BECAUSE AN EARLIER DRAFT OF THIS COMMENT OMITTED IT.
# It said "every snapshot at or before 2026-08-05 carries position 13, and
# every snapshot from 2026-08-08 onward carries position 1" — true of 43 of the
# 44, and the one it dropped is the ONLY sample between the two dates, i.e.
# precisely the transition the paragraph exists to describe. A clean
# before/after reads as a sharper finding than a three-state one, which is
# exactly why the inconvenient sample is the one that goes missing. Caught by
# the skeptic on this change.
#
# So the SYMPTOM is repaired and the gate that certified it clean throughout
# was never changed. That is what this surface is for.
#
# WHAT THIS CAN AND CANNOT SEE, stated because a scope claim needs a
# direction. This guard runs BEFORE `claude` execs, so the CHILD's future
# snapshot does not exist yet and cannot be inspected — #654 is right that no
# amount of tuning reaches it. What this guard CAN see is the PATH of its own
# process, which is a real agent surface in both of its call shapes, though
# not equally: in the DIAGNOSTIC path it IS the buried tool shell, which is the
# case `#654` filed and the case this surface catches. In the SPAWN path it is
# the immediately preceding bash, whose PATH `bash_env.sh` step (b) has ALREADY
# re-fronted — because every non-interactive bash both records (a0) and repairs
# (b), the record the guard reads describes a shell the prelude has already
# fixed. So the ambient surface is structurally blind to burial inherited from
# any shell above the last bash in the chain, and the spawn path is covered by
# the SNAPSHOT surface below, not by this one.
#
# Wording supplied verbatim by the skeptic `wpathsk`, which MEASURED it:
# launcher one hop up holds the buried value, the guard does not; the guard
# exits 0 with zero ambient refusals where the same guard handed that value
# directly exits 1 with three. The three ambient suite cases set
# NEXUS_INHERITED_PATH on the invocation line, so they exercise the CONSUMER
# and never the producer-to-consumer channel — the one hop where the value is
# destroyed is the one hop nothing covers. Not a fail-open regression (the
# snapshot leg catches the spawn case); the defect was the ATTRIBUTION, which
# is why it read plausibly for as long as it did.
#
# WHY THE ENFORCEABLE SIGNAL IS *BURIAL* AND NOT MERE ABSENCE. Refusing
# whenever a guarded name resolves off-shim in the ambient PATH would refuse
# in every test fixture, whose shim dirs are temp directories that were never
# fronted anywhere — and it would do so by discriminating on the FIXTURE
# rather than on the property, which this file's own suite already forbids
# (it asserts the verdict must not depend on which override the caller set).
# So the adjudicated signal is the one #578/#652 actually produce: the shim
# directory IS on this PATH and something resolves AHEAD of it. That is a
# front that was applied and then defeated — confirmed-bad, and impossible to
# reach from a fixture whose shim dir is not on PATH at all.
#
# The residual, named rather than hidden: a shim dir ABSENT from the ambient
# PATH is reported as a scoped WARNING, not a refusal. It errs toward
# ALLOWING, and the reason it is not a refusal is that this guard is run in
# contexts (its own suite, CI, an operator shell) where an unfronted ambient
# PATH is normal and a refusal would halt every spawn on the board.
# THE AMBIENT PATH IS THE ONE THIS PROCESS INHERITED, NOT ITS LIVE $PATH.
# monitor/shellenv/bash_env.sh re-fronts PATH at the start of every
# non-interactive bash — including this guard — so by line 1 the guard's own
# $PATH has already been repaired and reports clean about a shell that is not
# the one at risk. bash_env.sh therefore records what it inherited, and that
# is the value adjudicated here. Falling back to $PATH when the record is
# absent is deliberate and is the WEAKER reading: it means the guard was
# invoked without the nexus prelude, so there is no separate caller PATH to
# recover and $PATH is the best available answer.
_asw_ambient_path() {
    printf '%s' "${NEXUS_INHERITED_PATH:-$PATH}"
}

# Resolve `$1` against an explicit PATH string, the way execvp would. Not
# `command -v`: that reads the LIVE $PATH, which is the wrong one here.
# Binaries only — an alias or function cannot be inherited across the exec
# that separates this guard from its caller, so there is nothing else to find.
_asw_resolve_in() {
    _asw_ri_n="${1:-}"; _asw_ri_path="${2:-}"
    [ -n "$_asw_ri_n" ] || return 1
    _asw_ri_ifs=$IFS
    IFS=:
    for _asw_ri_d in $_asw_ri_path; do
        [ -n "$_asw_ri_d" ] || continue
        if [ -x "$_asw_ri_d/$_asw_ri_n" ] && [ ! -d "$_asw_ri_d/$_asw_ri_n" ]; then
            IFS=$_asw_ri_ifs
            printf '%s/%s' "$_asw_ri_d" "$_asw_ri_n"
            return 0
        fi
    done
    IFS=$_asw_ri_ifs
    return 1
}

# `_asw_dir_on_path_in <dir> <path-string>` asks about an EXPLICIT PATH; the
# bare `_asw_dir_on_path <dir>` asks about the ambient one (unchanged callers).
_asw_dir_on_path() { _asw_dir_on_path_in "${1:-}" "$(_asw_ambient_path)"; }
_asw_dir_on_path_in() {
    _asw_dop_d="${1:-}"; _asw_dop_path="${2:-}"
    [ -n "$_asw_dop_d" ] || return 1
    _asw_dop_r=$(_asw_rp "$_asw_dop_d" 2>/dev/null || true)
    _asw_dop_ifs=$IFS
    IFS=:
    for _asw_dop_e in $_asw_dop_path; do
        [ -n "$_asw_dop_e" ] || continue
        if [ "$_asw_dop_e" = "$_asw_dop_d" ]; then IFS=$_asw_dop_ifs; return 0; fi
        if [ -n "$_asw_dop_r" ]; then
            _asw_dop_er=$(_asw_rp "$_asw_dop_e" 2>/dev/null || true)
            if [ -n "$_asw_dop_er" ] && [ "$_asw_dop_er" = "$_asw_dop_r" ]; then
                IFS=$_asw_dop_ifs; return 0
            fi
        fi
    done
    IFS=$_asw_dop_ifs
    return 1
}

# Which shim dir ships `$1`, and is that dir on the ambient PATH? Answers
# through the ENUMERATED dirs, never a literal path, so it inherits the
# never-hand-maintained property the shim set already has.
_asw_shimdir_on_path() { _asw_shimdir_on_path_in "${1:-}" "$(_asw_ambient_path)"; }
_asw_shimdir_on_path_in() {
    _asw_sdp_n="${1:-}"; _asw_sdp_path="${2:-}"
    [ -n "$_asw_sdp_n" ] || return 1
    while IFS= read -r _asw_sdp_d; do
        [ -n "$_asw_sdp_d" ] || continue
        [ -x "$_asw_sdp_d/$_asw_sdp_n" ] || continue
        if _asw_dir_on_path_in "$_asw_sdp_d" "$_asw_sdp_path"; then return 0; fi
    done <<EOF
${_asw_dirs}
EOF
    return 1
}

# Why an unwrapped name matters — the operator-facing consequence, per hazard
# class. An unknown name still gets a correct, generic line.
_asw_hazard_note() {
    case "${1:-}" in
        gh)
            printf 'GitHub writes would not auto-inject the bot token (identity-leak class, #578).' ;;
        pip|pip3)
            printf 'FAIL-OPEN: the sandbox-wrapped %s re-execs without bound and has taken this node down (#487) — a bare `%s` here RUNS.' "$1" "$1" ;;
        sandbox-notify)
            printf 'operator notifications would bypass the engagement gate.' ;;
        tmux)
            printf 'FAIL-OPEN: a board-lethal kill (kill-server, or the last window of the last session) would run UNCHECKED, and ending the server tears down the whole sandbox with no in-sandbox recovery (#644, #892).' ;;
        *)
            printf 'this PATH-front guard would not apply to `%s`.' "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Probe surfaces
# ---------------------------------------------------------------------------
_asw_probe_shell="${NEXUS_ASSERT_GH_SHELL:-${SHELL:-/usr/bin/zsh}}"
_asw_probe_ok=1
if ! command -v "$_asw_probe_shell" >/dev/null 2>&1 && [ ! -x "$_asw_probe_shell" ]; then
    _asw_not_checked "probe shell '$_asw_probe_shell' not found — shim reachability in the agent's own shell was not verified; allowing spawn."
    _asw_probe_ok=0
fi
_asw_base=$(basename -- "$_asw_probe_shell" 2>/dev/null || printf '%s' "$_asw_probe_shell")

# Resolve every guarded name inside ONE spawned shell, printing
# `SHIMMARK:<name>:<resolved>` lines. The marker isolates our answers from any
# banner the operator's interactive rc prints.
#
# The name list rides in an env var and is walked with `tr` + `while read`
# rather than an unquoted-parameter `for` loop: this snippet must run under BOTH
# zsh and bash, and zsh does NOT word-split unquoted parameters (`for n in $VAR`
# would iterate ONCE over the whole string — the workspace's documented
# zsh-is-not-bash trap).
_asw_run_probe() {
    _asw_flags="$1"
    # THE AMBIENT SURFACE SPAWNS NOTHING. Resolving in THIS process is the
    # entire point: a spawned shell re-derives PATH and would answer the
    # question that #652/#654 showed was the wrong one.
    if [ "$_asw_flags" = "--ambient" ]; then
        _asw_amb=$(_asw_ambient_path)
        while IFS= read -r _asw_an; do
            [ -n "$_asw_an" ] || continue
            printf '%s:%s\n' "$_asw_an" "$(_asw_resolve_in "$_asw_an" "$_asw_amb" 2>/dev/null)"
        done <<EOF
${_asw_names}
EOF
        return 0
    fi
    _asw_cmd='printf "%s\n" "$NEXUS_ASSERT_SHIM_NAMES" | tr " " "\n" | while IFS= read -r _n; do
        [ -n "$_n" ] || continue
        printf "SHIMMARK:%s:%s\n" "$_n" "$(command -v -- "$_n" 2>/dev/null)"
    done'
    # An interactive zsh probe runs the operator's ~/.zshrc, which typically
    # calls compinit — and compinit dumps to ${ZDOTDIR}/.zcompdump, i.e. INTO
    # monitor/shellenv. Redirect where we can (oh-my-zsh honours ZSH_COMPDUMP;
    # native compinit's dumpfile is settable only via `compinit -d`), and rely
    # on the .gitignore entry otherwise. On a read-only tree the write just
    # fails, harmlessly.
    ZSH_COMPDUMP="${TMPDIR:-/tmp}/.nexus-assert-zcompdump.$$"
    NEXUS_ASSERT_SHIM_NAMES=$(printf '%s' "$_asw_names" | tr '\n' ' ')
    export ZSH_COMPDUMP NEXUS_ASSERT_SHIM_NAMES
    _asw_probe_exec "$_asw_probe_shell" $_asw_flags "$_asw_cmd" 2>/dev/null \
        | sed -n 's/^SHIMMARK://p'
    rm -f "$ZSH_COMPDUMP" 2>/dev/null || true
}

# _asw_probe_exec <shell> <flags...> <cmd>
#
# Run a probe shell with NO controlling tty, stdin from /dev/null, and a
# timeout that ESCALATES to SIGKILL (your-org/nexus-code#1497).
#
# WHY. Every launcher that runs this guard runs it inside a tmux pane, and an
# INTERACTIVE shell (`-lic`, `-ic`) started there by a plain `timeout 40 …`
# is in a BACKGROUND process group of the pane's tty (GNU timeout puts its
# child in its own group so it can kill the group). POSIX job control stops
# such a shell with SIGTTIN/SIGTTOU the moment it touches the terminal, before
# it can run the `-c` command. Measured on 2026-09-06/08 (zsh 5.4.2, bash
# 4.4.20, GNU timeout 8.28, in a pane shaped exactly like
# `_respawn.sh`'s launcher — 4 of 4 runs): the shell sits in state T; at 40 s
# the bare `timeout` sends SIGTERM, which an interactive shell IGNORES once
# its signal setup has run, and then waits forever — no `-k`, nothing
# stronger to send. The launcher never reaches `exec claude`, and
# `pane-state.sh` reads `unknown reason=live-descendant` for the window. Two
# orchestrator boots of one nexus hung this way on 2026-09-06 (the watcher
# logged `input-ready probe timed out … last state='unknown'` and every emit
# `FAILED rc=4`). The milder outcome — the stopped shell dies on the TERM,
# the surface comes back EMPTY after 40 s and the guard "allows" having
# learned nothing — is the one every other operator has been paying since
# the probe landed (#578): a 40 s tax per spawn and a blind surface.
#
# THE FIX IS THE MORE FAITHFUL MODEL, not a workaround: Claude Code takes the
# very shell snapshot this probe stands in for from a SUBPROCESS WITH NO TTY.
# `setsid` gives the probe the same footing (no controlling terminal, so no
# job-control stop and nothing to read from), `</dev/null` closes the other
# door, and `-k` makes the bound a bound.
#
# ORDER MATTERS: `setsid` OUTSIDE, `timeout` INSIDE. GNU timeout kills its
# direct child and then its own process group (`kill(0, sig)`), which is
# where the child's descendants live. Run the other way round (`timeout …
# setsid …`) the shell lands in a NEW session and only the shell itself is
# ever signalled: a descendant it spawned before wedging — an rc chain's
# `tmux`, a `sleep`, anything — survives, keeps the output pipe open, and the
# guard waits for IT. Measured while writing the test for this: a probe shell
# that ignored SIGTERM and slept was killed on schedule, yet the guard
# returned only when its orphaned `sleep` did. With `setsid -w timeout …` the
# whole detached group goes down at the bound. `setsid -w` execs in place
# when the caller is not a group leader (the normal case here) and waits for
# the child when it has to fork, so the exit status and the pipe both stay
# attached to the probe.
#
# The two numbers are knobs so a test can drive the KILL path in seconds:
#   NEXUS_ASSERT_PROBE_TIMEOUT     seconds before SIGTERM (default 40)
#   NEXUS_ASSERT_PROBE_KILL_GRACE  seconds after that before SIGKILL (default 5)
# Non-numeric values fall back to the defaults rather than to an unbounded
# probe.
_asw_probe_timeout="${NEXUS_ASSERT_PROBE_TIMEOUT:-40}"
case "$_asw_probe_timeout" in ''|*[!0-9]*) _asw_probe_timeout=40 ;; esac
_asw_probe_kill_grace="${NEXUS_ASSERT_PROBE_KILL_GRACE:-5}"
case "$_asw_probe_kill_grace" in ''|*[!0-9]*) _asw_probe_kill_grace=5 ;; esac
# WHY A GUARANTEED RETURN IS SAFE HERE — AND WHAT WOULD MAKE IT UNSAFE
# (your-org/nexus-code#1498 review). `-k` turns the bound into a bound: a probe
# shell that ignores SIGTERM is KILLED and its surface comes back EMPTY. That
# is only safe because an EMPTY surface ALLOWS — the two degrade-to-allow arms
# below, at the `did not resolve at all (empty)` warning and at the `gh`
# version-floor warning, neither of which sets `_asw_refused`.
#
# THE TWO ARE COUPLED AND THE COUPLING IS INVISIBLE FROM EITHER END. Hardening
# an empty surface into a REFUSAL looks entirely local to the adjudication
# block; on that day `-k` silently converts a rare hang into a DETERMINISTIC
# spawn refusal on every host with a controlling tty, because a killed probe
# always yields an empty surface. If you change what an empty surface does,
# this function is the other half of that change. Case 13c pins the ALLOW.
_asw_probe_exec() {
    if command -v setsid >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            setsid -w timeout -k "$_asw_probe_kill_grace" "$_asw_probe_timeout" "$@" </dev/null
        else
            setsid -w "$@" </dev/null
        fi
    elif command -v timeout >/dev/null 2>&1; then
        timeout -k "$_asw_probe_kill_grace" "$_asw_probe_timeout" "$@" </dev/null
    else
        "$@" </dev/null
    fi
}

_asw_refused=0
_asw_warned=0
_asw_carveout=0
_asw_shim_refused=0   # a SHIM probe (not the nproc leg) is what refused

# Enforceability per surface (unchanged from #578's reasoning):
#   -c    non-interactive — the direct tool `<$SHELL> -c` surface and every
#         nested subshell. ENFORCEABLE for both shells: locals-env exports
#         ZDOTDIR/.zshenv (zsh) and BASH_ENV/bash_env.sh (bash), both of which
#         re-front. A failure here is a genuine break.
#   -lic  login+interactive — the shape Claude Code snapshots for its Bash tool,
#         and the surface #578 broke. ENFORCEABLE under ZSH (the .zshrc /
#         .zprofile / .zlogin proxies re-front after the operator's rc). NOT
#         enforceable under BASH: interactive bash reads ~/.bashrc, for which
#         the nexus has no re-front hook (no ZDOTDIR analog), so a bash `-lic`
#         miss WARNS rather than halting every spawn on a bash host over a
#         surface we cannot fix from here.
case "$_asw_base" in
    zsh*) _asw_lic_enforceable=1 ;;
    *)    _asw_lic_enforceable=0 ;;
esac

# Ordering matters for the 79 contract: the EXPLICIT opt-out is tested first,
# so a caller that disabled this leg does not also collect a "no shim dirs"
# NOT-CHECKED for the leg it just turned off. That is the declared residual in
# this file's header, expressed as control flow rather than as prose.
if [ "${NEXUS_ASSERT_SKIP_SHIMS:-}" = 1 ]; then
    _asw_say "shim-reachability probes skipped by explicit request (NEXUS_ASSERT_SKIP_SHIMS=1)."
elif [ "$_asw_have_shims" = 1 ] && [ "$_asw_probe_ok" = 1 ]; then
    # AMBIENT FIRST — it is the surface the caller is actually running in, and
    # putting it first means a buried caller is named before two spawned
    # shells report the ordering it does not have.
    #
    # Its enforceability token is `burial`, not 0/1: adjudicated as a REFUSAL
    # when the shim dir is on this PATH and something resolves ahead of it,
    # and as a scoped WARNING when the shim dir is not on this PATH at all.
    # See the AMBIENT SURFACE block above for why that is the property line.
    for _asw_spec in \
        "ambient (the PATH this guard INHERITED):--ambient:burial" \
        "non-interactive (tool -c):-c:1" \
        "login+interactive (snapshot source):-lic:$_asw_lic_enforceable"; do
        _asw_lbl="${_asw_spec%%:*}"
        _asw_rest="${_asw_spec#*:}"
        _asw_flg="${_asw_rest%%:*}"
        _asw_enf="${_asw_rest##*:}"

        _asw_run_probe "$_asw_flg" > "$_asw_tmp.probe" 2>/dev/null || true

        # Walk the GUARDED NAMES (not the probe output), so a name that produced
        # no line at all — probe died mid-way, shim dir added after the probe
        # started — is still adjudicated rather than silently skipped.
        while IFS= read -r _asw_name; do
            [ -n "$_asw_name" ] || continue
            _asw_res=$(awk -v n="$_asw_name" -F: '$1 == n { r = substr($0, length(n) + 2) } END { print r }' \
                        "$_asw_tmp.probe" 2>/dev/null)

            if [ -z "$_asw_res" ]; then
                # The ambient surface spawns no shell, so naming one here
                # would misattribute the observation to a probe that never ran.
                _asw_who="$_asw_base $_asw_lbl"
                [ "$_asw_enf" = burial ] && _asw_who="$_asw_lbl"
                _asw_say "WARNING: $_asw_who: \`$_asw_name\` did not resolve at all (empty). Not a hazard on its own (a missing command fails loudly on use), so allowing — but the shim is not on PATH here."
                _asw_warned=1
                continue
            fi

            case "$_asw_res" in
                /*)
                    if _asw_under_shim "$_asw_res"; then
                        continue                       # pass
                    fi
                    _asw_msg="\`$_asw_name\` resolves to '$_asw_res', NOT under a shim dir. $(_asw_hazard_note "$_asw_name")"
                    ;;
                *)
                    # A non-absolute answer means an alias, shell function or
                    # builtin is shadowing a guarded name AHEAD of the shim.
                    # That is USUALLY a bypass by another route — a confirmed-bad
                    # state, not an unknown one.
                    #
                    # THE EXCEPTION: A SELF-PREFIXING ALIAS IS TRANSPARENT TO A
                    # PATH-FRONT SHIM (your-org/nexus-code#892, skeptic F1).
                    # An alias whose expansion's FIRST WORD is the alias name
                    # itself — `tmux='tmux -2'`, `ls='ls --color=auto'`, the
                    # commonest shape in any operator's rc — does not bypass
                    # anything: zsh will not recursively re-expand the head, so
                    # the expanded first word resolves through PATH and lands on
                    # the shim. Only the extra flags are prepended.
                    #
                    # Treating it as a bypass is not a harmless over-refusal. It
                    # is a TOTAL SPAWN WEDGE: every agent launcher runs this gate
                    # and aborts on non-zero, so one alias in ~/.zshrc halts the
                    # whole board — and this guard exists precisely to keep the
                    # board alive. Measured on this host with `alias tmux='tmux
                    # -2'` live: the aliased kill still reached the shim and was
                    # REFUSED, i.e. the guard applied and the refusal's premise
                    # was false.
                    #
                    # An alias whose first word DIFFERS
                    # (`tmux='/usr/bin/tmux -2'`, `gh='hub'`) genuinely does
                    # bypass the shim, and still refuses.
                    _asw_alias_head=$(printf '%s' "$_asw_res" \
                        | sed -n "s/^alias $_asw_name=//p" \
                        | sed "s/^['\"]//; s/['\"]$//" \
                        | awk '{print $1}')
                    if [ -n "$_asw_alias_head" ] && [ "$_asw_alias_head" = "$_asw_name" ]; then
                        _asw_say "NOTE: $_asw_base $_asw_lbl: \`$_asw_name\` is aliased SELF-PREFIXING ('$_asw_res'). The expansion's head is \`$_asw_name\` itself, which zsh does not re-expand, so it still resolves through PATH to the shim. Not a bypass; allowing."
                        continue
                    fi
                    _asw_msg="\`$_asw_name\` is SHADOWED by a shell alias/function ('$_asw_res') ahead of the shim. $(_asw_hazard_note "$_asw_name")"
                    ;;
            esac

            if [ "$_asw_enf" = burial ]; then
                # BURIED: the front was applied here and then defeated. This is
                # the #578/#652 signature and it is confirmed-bad.
                if _asw_shimdir_on_path "$_asw_name"; then
                    _asw_refused=1; _asw_shim_refused=1
                    _asw_say "REFUSING SPAWN: $_asw_lbl: $_asw_msg"
                    _asw_say "  The shim directory IS on the INHERITED PATH and \`$_asw_name\` resolves AHEAD of it."
                    _asw_say "  That is a front that was applied and then BURIED — the #578 signature, in the"
                    _asw_say "  surface the caller is actually running in. A freshly spawned probe shell"
                    _asw_say "  re-derives PATH and would report this clean (your-org/nexus-code#652, #654)."
                else
                    # NOT ADJUDICABLE, and said so rather than folded into the
                    # pass. This is the guard looking and judging an individual
                    # item, so it is a warning and not the 79 outcome.
                    _asw_warned=1
                    _asw_say "WARNING: $_asw_lbl: $_asw_msg"
                    _asw_say "  The shim directory is NOT on the INHERITED PATH at all, so this is not the"
                    _asw_say "  buried-front signature and is not adjudicated as a failure. What is NOT"
                    _asw_say "  established: that a bare \`$_asw_name\` from THIS shell reaches the shim. It does not."
                fi
            elif [ "$_asw_enf" = 1 ]; then
                _asw_refused=1; _asw_shim_refused=1
                _asw_say "REFUSING SPAWN: $_asw_base $_asw_lbl: $_asw_msg"
            else
                _asw_carveout=1; _asw_warned=1
                _asw_say "CARVE-OUT (not enforceable for $_asw_base): $_asw_lbl: $_asw_msg"
                _asw_say "  interactive $_asw_base cannot be re-fronted from the nexus (no ~/.bashrc hook);"
                _asw_say "  this spawn is NOT protected by that shim on that surface."
            fi
        done <<EOF
${_asw_names}
EOF
    done

    # ONE HOP ABOVE THE CALLER (your-org/nexus-code#1383). The ambient surface
    # adjudicates the PATH this process INHERITED — and in the SPAWN path that
    # caller is a bash launcher whose own prelude had ALREADY re-fronted before
    # exporting PATH to us, so the reading above describes a repaired shell and
    # a silent clean there was a question the surface could not answer. The
    # prelude now carries the caller's OWN inherited PATH forward, one hop,
    # keyed on pid identity (bash_env.sh a0). When it is present, that value
    # is adjudicated here for the same burial signature — as a WARNING, never
    # a refusal: a refusal on this surface reaches `_respawn.sh` at exit 78
    # and the board cannot self-heal (#670). An earlier version of this
    # comment added "and the SNAPSHOT surface below already covers the spawn
    # case with a mutation-proven refusal" — which named the hazard on THIS
    # leg and delegated to the leg that carried it: the snapshot leg's refusal
    # reached `_respawn.sh` identically, and on 2026-09-06 it did, for 18 h
    # (your-org/nexus-code#1477, D1). The snapshot leg now applies the same
    # rule on the orchestrator path (`NEXUS_IS_ORCHESTRATOR=1`) and keeps its
    # refusal for WORKER spawns only; see that leg for the error direction.
    if [ -n "${NEXUS_INHERITED_PATH_UPSTREAM:-}" ]; then
        _asw_say "NOTE: ambient: the caller (pid ${NEXUS_INHERITED_PATH_UPSTREAM_PID:-?}) had already run the nexus prelude and re-fronted before exporting PATH to this guard, so the ambient reading above describes a REPAIRED shell. Adjudicating the PATH that caller itself inherited (one hop up; your-org/nexus-code#1383):"
        while IFS= read -r _asw_up_name; do
            [ -n "$_asw_up_name" ] || continue
            _asw_up_res=$(_asw_resolve_in "$_asw_up_name" "$NEXUS_INHERITED_PATH_UPSTREAM" 2>/dev/null) || _asw_up_res=""
            [ -n "$_asw_up_res" ] || continue
            if _asw_under_shim "$_asw_up_res"; then continue; fi
            if _asw_shimdir_on_path_in "$_asw_up_name" "$NEXUS_INHERITED_PATH_UPSTREAM"; then
                _asw_warned=1
                _asw_say "WARNING: ambient (one hop above the caller): \`$_asw_up_name\` resolves to '$_asw_up_res' AHEAD of the shim dir in the PATH the caller inherited. $(_asw_hazard_note "$_asw_up_name")"
                _asw_say "  A front applied and then BURIED in the shell above the last bash in the chain (the #652/#654 signature)."
                _asw_say "  NOT adjudicated as a refusal: the snapshot surface covers the spawn, and a refusal here would reach _respawn.sh (#670)."
            fi
        done <<EOF
${_asw_names}
EOF
    fi
elif [ "$_asw_have_shims" != 1 ]; then
    # "Nothing to enforce" is NOT "enforced and clean" (your-org/nexus-code#612).
    # This is the branch a fork, an older checkout, or a NEXUS_ROOT re-rooted
    # onto a tree that predates the shims lands in — and it used to return the
    # same 0 as a full clean pass, in a message the caller could only find by
    # reading stderr it had no reason to read.
    _asw_not_checked "no shim dirs found under '${_asw_glob:-<nowhere to look>}' — nothing to enforce (fork / older checkout), and therefore nothing verified."
    if [ -n "$_asw_root" ]; then
        _asw_say "  if \$NEXUS_ROOT ($_asw_root) is a re-rooted primary, the shims being enforced are not the ones this spawn shipped with (your-org/nexus-code#577)."
    fi
fi

# ---------------------------------------------------------------------------
# `gh` VERSION FLOOR: the EFFECTIVE client, measured end-to-end (#755).
# ---------------------------------------------------------------------------
# The legs above answer "does a bare `gh` reach the wrapper?" — reachability.
# That is necessary and NOT sufficient, and #755 is exactly the gap: a
# correctly-fronted wrapper faithfully forwarding the bot token to a five-year-
# old client. Verified on this host: with the wrapper PATH-FRONT but /app/bin
# ahead of linuxbrew, `gh --version` still reported 1.13.0. So reachability
# passing tells you nothing about capability.
#
# WHAT IS MEASURED. This leg does NOT scan PATH for a capable binary, and does
# NOT read the wrapper's resolution logic. It asks the probe shell to run a bare
# `gh --version` — the same lookup, through the same wrapper — and reads the
# version that actually comes back. The alternative ("a capable gh exists
# somewhere on PATH") would have PASSED on the very host where #755 was
# observed, because 2.89.0 was installed the whole time and simply lost the
# ordering.
#
# WHAT IT DOES NOT LICENSE, stated because an earlier draft of this comment
# called it "end-to-end" and that overstates it (skeptic finding F3). The probe
# is `$SHELL -c` — NON-login, NON-interactive. Claude Code's Bash tool sources a
# FROZEN SNAPSHOT captured in a LOGIN+INTERACTIVE shell, which is the shape
# `#578` identifies as the one that loses the PATH race. So this leg speaks for
# a FRESHLY SPAWNED worker — which is exactly what a spawn gate gates — and is
# structurally blind to a session already running on a stale snapshot. That
# blindness is `#652`, and PR `#670` is the open remedy; it is a declared
# boundary here, not a claim.
#
# THREE STATES, and the middle one DEFAULTS TO WARN rather than refuse:
#   >= floor            pass, silently
#   <  floor            WARNING + durable breadcrumb; REFUSAL only under
#                       NEXUS_REQUIRE_GH_FLOOR=1
#   version unreadable  NOT CHECKED (79) — never folded into a pass
#
# The default-warn is a deliberate line, not timidity. A refusal here reaches
# `monitor/watcher/_respawn.sh`, which renders guard-block.sh.in with
# @@ACTION@@ → RESPAWN and exits 78 on a guard refusal — so a default-refuse
# would mean the board cannot self-heal if the orchestrator dies, on a nexus
# the operator cannot restart. PR #670 paid for that lesson on the sibling leg
# and it is not worth re-learning. The SILENT half of #755 is already closed
# unconditionally by the wrapper's prefer-capable resolution; this leg exists
# so that the residual — a host with no capable client at all — cannot pass
# unremarked. Set NEXUS_REQUIRE_GH_FLOOR=1 to make it binding.
_asw_ghfloor_skip=0
case "
${_asw_names}" in
    *"
gh
"*) : ;;
    *)  _asw_ghfloor_skip=1 ;;    # `gh` is not a guarded name here — nothing to say
esac

if [ "${NEXUS_ASSERT_SKIP_GH_FLOOR:-}" = 1 ]; then
    _asw_say "gh version-floor leg skipped by explicit request (NEXUS_ASSERT_SKIP_GH_FLOOR=1)."
elif [ "$_asw_ghfloor_skip" = 1 ] || [ "${NEXUS_ASSERT_SKIP_SHIMS:-}" = 1 ]; then
    : # no gh shim to speak of, or the whole shim leg was opted out of above
elif [ "$_asw_probe_ok" != 1 ]; then
    : # the missing probe shell already recorded NOT CHECKED above; do not double-count
else
    _asw_floor="${NEXUS_GH_MIN_VERSION:-2.86.0}"
    # A bare `gh --version` in the agent's own shell. Marker-delimited for the
    # same reason the shim probe uses one: an interactive rc may print a banner.
    _asw_ghv_raw=$(
        _asw_probe_exec "$_asw_probe_shell" -c 'printf "GHVERMARK:%s\n" "$(gh --version 2>/dev/null | head -1)"' 2>/dev/null \
            | sed -n 's/^GHVERMARK://p' | head -1
    )
    _asw_ghv=$(printf '%s' "$_asw_ghv_raw" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^v?[0-9]+\.[0-9]+/) { print $i; exit } }')
    _asw_ghv="${_asw_ghv#v}"
    _asw_ghv=$(printf '%s' "$_asw_ghv" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\).*$/\1/p')

    if [ -z "$_asw_ghv" ]; then
        # WARNING, deliberately NOT 79 — and the distinction is this file's own,
        # drawn on its own axis. 79 means the guard could not examine its
        # SUBJECT AT ALL (no root, no shim dirs, no probe shell). Here the guard
        # did examine it: it ran `gh --version` in the agent's shell and got an
        # answer it could not parse. That is an adjudication about an individual
        # item, which is the WARNING side of the boundary — the same side as
        # "could not read RLIMIT_NPROC from a python subprocess" below. Folding
        # it into 79 would also make every synthetic-shim fixture in this
        # file's suite report NOT CHECKED, which is the tell that the axis was
        # wrong rather than the fixtures being wrong.
        _asw_warned=1
        _asw_say "WARNING: could not read a \`gh\` version from the agent's own shell (got: '${_asw_ghv_raw:-<empty>}') — the EFFECTIVE client's capability is unverified (#755). Allowing: an unusable \`gh\` fails loudly on use."
    else
        # numeric M.m.p compare, no `sort -V`
        _asw_ge=1
        _asw_i=1
        while [ "$_asw_i" -le 3 ]; do
            _asw_x=$(printf '%s' "$_asw_ghv"  | cut -d. -f"$_asw_i"); _asw_x=${_asw_x:-0}
            _asw_y=$(printf '%s' "$_asw_floor" | cut -d. -f"$_asw_i"); _asw_y=${_asw_y:-0}
            case "$_asw_x" in ''|*[!0-9]*) _asw_x=0 ;; esac
            case "$_asw_y" in ''|*[!0-9]*) _asw_y=0 ;; esac
            if [ "$_asw_x" -gt "$_asw_y" ]; then _asw_ge=0; break; fi
            if [ "$_asw_x" -lt "$_asw_y" ]; then _asw_ge=1; break; fi
            _asw_ge=0
            _asw_i=$((_asw_i + 1))
        done

        if [ "$_asw_ge" != 0 ]; then
            _asw_ghmsg="the \`gh\` the agent will actually run is $_asw_ghv, BELOW the declared floor $_asw_floor. Measured on this host against one 10-job run: 1.3.1 returns 0 of 10 jobs from \`run view --log\`, 1.13.0 and 2.14.7 return 2 of 10, and 1.13.0 additionally prints \`pass\` for a check whose REST conclusion is \`skipped\`. Only >= 2.86.0 returned all 10 (your-org/nexus-code#755)."
            if [ "${NEXUS_REQUIRE_GH_FLOOR:-}" = 1 ]; then
                _asw_refused=1; _asw_shim_refused=1
                _asw_say "REFUSING SPAWN: $_asw_ghmsg"
            else
                _asw_warned=1
                _asw_say "WARNING: $_asw_ghmsg"
                _asw_say "  allowing the spawn (a refusal here also blocks orchestrator RESPAWN via _respawn.sh's 78). Set NEXUS_REQUIRE_GH_FLOOR=1 to make this binding."
                _asw_say "  fix: install a gh >= $_asw_floor reachable on the agent's PATH; the wrapper prefers the first candidate meeting the floor."
            fi
            if [ -n "$_asw_root" ] && [ -d "$_asw_root/monitor/.state" ]; then
                printf '%s\tversion=%s\tfloor=%s\tshell=%s\twindow=%s\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown-ts)" \
                    "$_asw_ghv" "$_asw_floor" "$_asw_base" \
                    "${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-unknown}}" \
                    >> "$_asw_root/monitor/.state/gh-below-floor.log" 2>/dev/null || true
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# PORTED FROM your-org/nexus-code#670 (closed in favour of this) — the
# FROZEN-SNAPSHOT surface, verbatim apart from this header.
#
# WHY BOTH SURFACES EXIST, because a reader will ask why one file probes the
# same hazard twice. They answer DIFFERENT QUESTIONS and each catches a case
# the other misses — measured, not argued, by running each against the other's
# fixture:
#
#   caller's PATH BURIED, snapshot CLEAN -> ambient REFUSES,  snapshot passes
#   caller's PATH CLEAN,  snapshot BURIED -> ambient passes,  snapshot REFUSES
#
# The AMBIENT surface measures the PATH that WILL BE USED by this process's
# caller. The SNAPSHOT surface measures the RECORDING that produces it — which
# is what every FUTURE tool call in an already-running session will replay. A
# session started before a PATH repair stays frozen on the bad recording for
# its whole life while every freshly spawned probe reports the fixed ordering,
# and that is the case #652 was filed from.
#
# #670 was a month stale (merge base 1,075 commits back) and CONFLICTING, and
# its base predates the SELF-PREFIXING-alias carve-out below (`#892` F1), so
# running it on this host refused UNCONDITIONALLY — a total spawn wedge, since
# every launcher aborts on non-zero. Measured with a CLEAN caller and a CLEAN
# snapshot: still rc 1, on `alias tmux='tmux -2'`. That is why this is a PORT
# onto current `dev` rather than a rebase, and why the carve-out is kept.
#
# NEAR-MISS WORTH RECORDING, because it nearly went into the disposition: the
# first cross-test read rc 1 from #670 on the caller-buried case and was about
# to credit it with catching that case. The refusal was real and about the
# alias. What separated them was a CONTROL — the same fixture with a clean
# caller — which refused too. A REFUSAL IS NOT EVIDENCE ABOUT THE VARIABLE YOU
# VARIED UNLESS THE CONTROL REFUSES TO REFUSE.
# THE FROZEN-SNAPSHOT SURFACE — your-org/nexus-code#652 / #654 / #1477
# ---------------------------------------------------------------------------
# Everything above probes a FRESHLY SPAWNED shell. That surface repairs
# itself: front-path.zsh runs last there and wins, so the probe passes —
# honestly. It is not lying about the shell it examined.
#
# The agent's Bash tool call is NOT a fresh shell. It is
#     /usr/bin/zsh -c source <cc-home>/shell-snapshots/snapshot-zsh-<id>.sh …
# a FROZEN ARTIFACT recorded once at Claude Code startup. A guard that
# re-derives a surface cannot see a defect baked into a recording of a
# different one — which is why this guard exited 0 while three separate
# workers resolved `gh` to linuxbrew and `pip` to /app/bin/pip.
#
# And the snapshot does NOT lack the shim dirs. Measured 2026-08-02, the
# snapshot's single `export PATH=` carried monitor/ghwrap at POSITION 13,
# behind /home/operator/Projects/utilities and the linuxbrew dirs: the
# front-path prepend ran, then ~/.zshrc's re-prepend won the #578 race,
# and the snapshot froze THAT ordering permanently. So the question is
# not presence, it is ORDER — exactly the question the live probe asks,
# asked of the recording.
#
# WHOSE SNAPSHOT. At SPAWN time the child's snapshot does not exist yet
# (Claude Code writes it at startup), so this leg necessarily adjudicates
# ANOTHER session's artifact and infers about the child. Which session's
# is the whole question, and the answer is ranked (see the selection
# block below): this process's own tool shell (ancestry), then the
# SPAWNING agent's (carried by the launcher, #1477), then — as a proxy
# that is REPORTED as one — the newest file in the CC home by mtime.
#
# THE ERROR DIRECTION, DECIDED HERE AND NOT ONE LEG OVER (your-org/nexus-code
# #1477). This leg used to be a hard refusal on EVERY spawn path, and the
# ambient leg above justified its own warn-only rule by pointing at it:
# "the SNAPSHOT surface already covers the spawn case". On 2026-09-06 the
# newest-by-mtime snapshot belonged to a `claude` launched OUTSIDE the nexus
# launcher — no ZDOTDIR, so no shim dir anywhere in its PATH — and this leg
# refused every spawn for 18 h, INCLUDING `_respawn.sh`: 1,104 failed
# respawns, 75 emits archived undelivered, and no self-heal, because the
# only thing that writes a nexus-provenance snapshot is a nexus-launched
# agent, which this leg was refusing to launch. Retrying could not clear
# it. Two rules follow, each with its direction stated:
#
#   FOREIGN vs BURIAL. The two signatures differ and only one is #652.
#     * shim dirs PRESENT in the snapshot's PATH but a guarded name
#       resolves AHEAD of them → BURIAL, the #578/#652/#654 race frozen
#       into a recording. Confirmed-bad about SOME nexus-launched shell.
#     * NO shim dir in that PATH AT ALL, while the live probes above just
#       found THIS spawn's own env correctly fronted → the recording is of
#       a shell that never had the nexus env: a FOREIGN artifact. It says
#       nothing about the child, which writes its own snapshot from the env
#       verified live. WARN loudly; never refuse. Errs toward ALLOWING a
#       spawn whose only evidence against it is somebody else's shell.
#       When the live probes did NOT run (no probe shell, NOT CHECKED),
#       a foreign snapshot is NOT CHECKED too — "could not look" must not
#       become a refusal on evidence about a different session.
#
#   THE SELF-HEAL PATH NEVER REFUSES HERE. `NEXUS_IS_ORCHESTRATOR=1` is
#     exported by every orchestrator spawn path (_respawn.sh's launcher;
#     spawn-fresh-orchestrator.sh through it). On that path a BURIAL is
#     a WARNING plus a durable row in monitor/.state/guard-unverified.log
#     plus a sandbox-notify — the same rule the ambient one-hop leg and
#     the `gh` floor leg already apply for the same reason. Errs toward
#     STARTING a possibly-buried orchestrator, deliberately: the measured
#     alternative is NO orchestrator, an unreachable board for every
#     remote user, and a latch nothing can clear — while a started
#     orchestrator writes a fresh nexus-provenance snapshot that clears
#     the latch for every worker spawn after it, and can repair the
#     shell-init itself. WORKER spawns keep the fail-CLOSED refusal on
#     burial: a refused worker is one window, not the board.
#
#   WHAT STILL CAN refuse an orchestrator respawn: the live probe legs
#     (this spawn's own `-c`/`-lic` shells miss a shim) and the nproc leg.
#     Those adjudicate THIS spawn's deterministic env, not a peer's
#     artifact, and they are not self-latching — a shellenv repair clears
#     them on the next attempt. Named here as the residual, not hidden.
# The LAST `export PATH=` of a snapshot file (the tool shell replays it top to
# bottom, so the final assignment wins), one layer of quotes stripped.
_asw_snap_path_of() {
    _asw_spo=$(sed -n 's/^[[:space:]]*export PATH=//p' "$1" 2>/dev/null | tail -1)
    case "$_asw_spo" in
        \"*\") _asw_spo=$(printf '%s' "$_asw_spo" | sed 's/^"//; s/"$//') ;;
        \'*\') _asw_spo=$(printf '%s' "$_asw_spo" | sed "s/^'//; s/'$//") ;;
    esac
    printf '%s' "$_asw_spo"
}
# Does ANY enumerated shim dir appear on this PATH string? Presence at any
# position means a nexus-fronted shell wrote it (ORDER is adjudicated per name
# later); absence at every position means the writer never had the nexus env.
_asw_path_has_shimdir() {
    while IFS= read -r _asw_phs_d; do
        [ -n "$_asw_phs_d" ] || continue
        if _asw_dir_on_path_in "$_asw_phs_d" "$1"; then return 0; fi
    done <<EOF
${_asw_dirs}
EOF
    return 1
}
# _asw_pick_snapshot <cc-home> — the mtime route, made PROVENANCE-AWARE
# (your-org/nexus-code#1477, skeptic F1). `ls -t | head -1` handed the leg ONE
# file, and a single FOREIGN file newer than a BURIED nexus one masked the
# burial entirely: rc 0 + "READ AS FOREIGN" with nothing said about the buried
# file beneath it — on the worker path that is #652 re-opened by one stray
# `claude`, and this host sat in exactly that mixed state for 43 minutes on
# 2026-09-06. So walk the listing newest-first and adjudicate the newest file
# that HAS nexus provenance; report FOREIGN only when no such file exists.
# Prints `<path>|<n-foreign-passed-over>` or nothing. Every candidate must sit
# under <cc-home>/shell-snapshots/ (the nullglob post-condition: an unmatched
# glob would make `ls -t` list the CWD and hand back RELATIVE names).
_asw_pick_snapshot() {
    _asw_ps_home="$1"; _asw_ps_first=""; _asw_ps_skipped=0
    _asw_ps_list=$(ls -t "$_asw_ps_home"/shell-snapshots/snapshot-*.sh 2>/dev/null)
    while IFS= read -r _asw_ps_f; do
        [ -n "$_asw_ps_f" ] || continue
        case "$_asw_ps_f" in "$_asw_ps_home"/shell-snapshots/*) : ;; *) continue ;; esac
        [ -r "$_asw_ps_f" ] || continue
        [ -n "$_asw_ps_first" ] || _asw_ps_first="$_asw_ps_f"
        if _asw_path_has_shimdir "$(_asw_snap_path_of "$_asw_ps_f")"; then
            printf '%s|%s' "$_asw_ps_f" "$_asw_ps_skipped"; return 0
        fi
        _asw_ps_skipped=$(( _asw_ps_skipped + 1 ))
    done <<EOF
${_asw_ps_list}
EOF
    [ -n "$_asw_ps_first" ] && printf '%s|-1' "$_asw_ps_first"
    return 0
}

if [ "${NEXUS_ASSERT_SKIP_SNAPSHOT:-}" != 1 ]; then
    _asw_snap="${NEXUS_ASSERT_SNAPSHOT:-}"
    _asw_snap_src=""

    # Did the LIVE probes above RUN and find THIS spawn's own env clean?
    # Three-valued on purpose: 1 = ran and clean, 0 = ran and refused,
    # "" = did not run (skipped, no shim dirs, no probe shell). A first
    # draft derived "clean" from `_asw_shim_refused = 0` alone, which reads
    # NOT-REFUSED as OBSERVED-CLEAN — the not-checked-equals-pass collapse
    # this file's exit-79 contract exists to forbid (#612). Recorded before
    # the snapshot leg runs, because the FOREIGN branch below turns on it.
    _asw_live_clean=""
    if [ "${NEXUS_ASSERT_SKIP_SHIMS:-}" != 1 ] && [ "$_asw_have_shims" = 1 ] && [ "$_asw_probe_ok" = 1 ]; then
        if [ "$_asw_shim_refused" = 0 ]; then _asw_live_clean=1; else _asw_live_clean=0; fi
    fi

    # The self-heal path (see the header above for the contract and the
    # tests that pin it). Only the literal "1" enables, matching every
    # other reader of this marker (hooks/orchestrator-session-pin.sh).
    _asw_selfheal=0
    [ "${NEXUS_IS_ORCHESTRATOR:-0}" = 1 ] && _asw_selfheal=1

    # Durable row for an announce-and-proceed outcome on this leg. The same
    # sink guard-block.sh.in's `_nx_note` writes — one file to read after
    # the fact to learn that an agent started with a known-defective
    # surface. Same mode discipline (0640 via _log-mode.sh or umask 0027,
    # your-org/nexus-code#484); failing to record is itself announced.
    _asw_record_unverified() {
        [ -n "$_asw_root" ] || { _asw_say "  (NEXUS_ROOT unset — the above is NOT durably recorded)"; return 0; }
        _asw_ulog="$_asw_root/monitor/.state/guard-unverified.log"
        mkdir -p "$_asw_root/monitor/.state" 2>/dev/null || true
        if [ -r "$_asw_root/monitor/_log-mode.sh" ]; then
            # shellcheck disable=SC1090
            . "$_asw_root/monitor/_log-mode.sh" 2>/dev/null && _ensure_service_log "$_asw_ulog"
        elif [ ! -e "$_asw_ulog" ]; then
            ( umask 0027; : >> "$_asw_ulog" ) 2>/dev/null || true
        fi
        if ! printf '%s\t%s\t%s\t%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown-ts)" \
                "assert-shims-wrapped" \
                "${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-unknown}}" \
                "$1" >> "$_asw_ulog" 2>/dev/null; then
            _asw_say "  could NOT record the above to $_asw_ulog — this spawn leaves no durable evidence of it."
        fi
    }

    # ANCESTRY FIRST — your-org/nexus-code#670 review, finding 1.
    #
    # Selecting `ls -t … | head -1` picks the newest snapshot written by
    # ANY Claude Code process. With ~15 concurrent agents and 46 snapshots
    # in one home, that is a PROXY for this spawn's artifact, not the
    # artifact — and the guard's own comment used to claim it "necessarily
    # examines the SPAWNING agent's". It did not. Verified on this host:
    # `ls -t` selected snapshot-…-0rkx7w.sh while this process's own tool
    # shell sources snapshot-…-ed2ccb.sh.
    #
    # It fails OPEN in the direction that matters most. After the
    # shell-init repair lands, the natural check is "does the guard pass
    # now?" — and ONE fresh good snapshot makes it pass while every
    # already-running agent stays frozen on a bad recording. That is a
    # green light for a repair which has not reached the population, i.e.
    # this guard's own defect class turned on its own verification loop.
    # And it fails CLOSED in the direction that took the board down: one
    # snapshot from a session that was never nexus-launched refuses every
    # spawn on the host (#1477).
    #
    # The linkage is exact and free: this guard runs as a descendant of
    # the Bash tool call, whose frame is literally
    #     zsh -c source <cc-home>/shell-snapshots/snapshot-<id>.sh …
    # so the path is in our own ancestry, verbatim. Walk up and read it.
    # `ls -t` remains as a fallback (a launcher may invoke us outside a
    # tool call), but which source was used is REPORTED, so a reader can
    # tell a measurement from an inference.
    if [ -z "$_asw_snap" ] && [ "${NEXUS_ASSERT_NO_ANCESTRY:-}" != 1 ]; then
        _asw_pid=$$
        _asw_hop=0
        while [ "$_asw_hop" -lt 8 ]; do
            _asw_line=$(ps -o ppid=,args= -p "$_asw_pid" 2>/dev/null | head -1) || break
            [ -n "$_asw_line" ] || break
            # `ps` right-pads the ppid column, so the line STARTS with
            # spaces and a bare `${line%% *}` yields the empty string —
            # which then fails the numeric test and breaks the walk on its
            # first hop, silently falling back to the mtime proxy this
            # whole block exists to replace. Strip leading blanks first.
            _asw_line=${_asw_line#"${_asw_line%%[![:space:]]*}"}
            _asw_ppid=${_asw_line%% *}
            case "$_asw_ppid" in ''|*[!0-9]*) break ;; esac
            # Take the LAST snapshot-looking token on the frame, so an
            # unrelated earlier path on the same command line cannot win.
            _asw_cand=$(printf '%s' "$_asw_line" \
                | tr ' ' '\n' \
                | grep -E '/shell-snapshots/snapshot-[^/]*\.sh$' \
                | tail -1)
            # NEXUS_CC_HOME, when set, is documented as the ONLY root
            # consulted — so an ancestry path OUTSIDE it must be ignored,
            # not preferred. Ancestry is ambient: without this, a hermetic
            # fixture that declares its own CC home still picks up the REAL
            # host's snapshot, which is the same leak the seam was added to
            # close, re-entering through a new door.
            if [ -n "$_asw_cand" ] && [ -n "${NEXUS_CC_HOME:-}" ]; then
                case "$_asw_cand" in
                    "$NEXUS_CC_HOME"/*) : ;;
                    *) _asw_cand="" ;;
                esac
            fi
            if [ -n "$_asw_cand" ] && [ -r "$_asw_cand" ]; then
                _asw_snap="$_asw_cand"
                _asw_snap_src="ancestry (frame $_asw_hop — the snapshot THIS process's tool shell sources)"
                break
            fi
            _asw_pid="$_asw_ppid"
            _asw_hop=$(( _asw_hop + 1 ))
        done
    fi
    # THE SPAWNER'S SNAPSHOT, carried by the launcher (your-org/nexus-code
    # #1477, D2). In the spawn path there is no `claude` ancestor — the
    # launcher is tmux's child, not the orchestrator's — so the walk above
    # always misses and used to fall straight through to the mtime proxy.
    # spawn-worker.sh runs INSIDE the spawning agent's tool shell, where the
    # walk does succeed, and exports what it found. That artifact is the one
    # this leg's header always said it examined: the spawning agent's, same
    # rc chain, a nexus-launched shell by construction — and if IT is
    # buried, so was the shell that decided to spawn. Scoped by NEXUS_CC_HOME
    # exactly like ancestry, for the same hermetic-fixture reason.
    if [ -z "$_asw_snap" ] && [ -n "${NEXUS_SPAWNER_SNAPSHOT:-}" ]; then
        _asw_cand="$NEXUS_SPAWNER_SNAPSHOT"
        if [ -n "${NEXUS_CC_HOME:-}" ]; then
            case "$_asw_cand" in
                "$NEXUS_CC_HOME"/*) : ;;
                *) _asw_say "NOTE: snapshot leg: NEXUS_SPAWNER_SNAPSHOT lies outside NEXUS_CC_HOME — ignored under the exclusive seam, not preferred."; _asw_cand="" ;;
            esac
        fi
        if [ -n "$_asw_cand" ] && [ -r "$_asw_cand" ]; then
            _asw_snap="$_asw_cand"
            _asw_snap_src="the SPAWNING agent's own tool shell, carried by the launcher (NEXUS_SPAWNER_SNAPSHOT; same rc chain as the child — #1477)"
        elif [ -n "$_asw_cand" ]; then
            _asw_say "NOTE: snapshot leg: NEXUS_SPAWNER_SNAPSHOT='$_asw_cand' is not readable — falling back to the mtime proxy."
        fi
    fi
    # NEXUS_CC_HOME, when set, is the ONLY root consulted — the same
    # hermetic-test seam _submit_evidence.sh uses, and it is load-bearing
    # here for a reason worth stating: a fixture that overrides HOME does
    # NOT necessarily override CLAUDE_CONFIG_DIR, so without an exclusive
    # seam this leg reads the REAL host's snapshot from inside a synthetic
    # fixture and reports on a surface the test never built.
    # The mtime route — PROVENANCE-AWARE (see _asw_pick_snapshot): the newest
    # file that has nexus provenance is adjudicated; foreign files newer than
    # it are counted and named in the route, never allowed to mask it.
    _asw_route_from_pick() {   # <pick-output> <home-label> -> sets _asw_snap/_asw_snap_src
        _asw_rfp="$1"; _asw_rfp_home="$2"
        [ -n "$_asw_rfp" ] || return 1
        _asw_snap="${_asw_rfp%|*}"; _asw_rfp_n="${_asw_rfp##*|}"
        if [ "$_asw_rfp_n" = -1 ]; then
            _asw_snap_src="newest in $_asw_rfp_home (mtime PROXY — not linked to this process; #670 finding 1); NO nexus-provenance snapshot exists there"
        elif [ "$_asw_rfp_n" = 0 ]; then
            _asw_snap_src="newest in $_asw_rfp_home (mtime PROXY — not linked to this process; #670 finding 1)"
        else
            _asw_snap_src="newest NEXUS-PROVENANCE snapshot in $_asw_rfp_home (mtime proxy; $_asw_rfp_n newer FOREIGN file(s) passed over rather than allowed to mask it — #1477 F1)"
        fi
        return 0
    }
    if [ -z "$_asw_snap" ] && [ -n "${NEXUS_CC_HOME:-}" ]; then
        _asw_route_from_pick "$(_asw_pick_snapshot "$NEXUS_CC_HOME")" "NEXUS_CC_HOME" || _asw_snap=''
        _asw_cc_scoped=1
    fi
    if [ -z "$_asw_snap" ] && [ -z "${_asw_cc_scoped:-}" ]; then
        for _asw_cch in ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR"} "$HOME/.claude"; do
            [ -d "$_asw_cch/shell-snapshots" ] || continue
            if _asw_route_from_pick "$(_asw_pick_snapshot "$_asw_cch")" "$_asw_cch"; then break; fi
        done
    fi

    if [ -z "$_asw_snap" ] || [ ! -r "$_asw_snap" ]; then
        _asw_not_checked "no readable Claude Code shell snapshot found — the surface the agent's tool calls actually source was not examined (#652). A fresh-shell pass says nothing about it."
    else
        # LAST `export PATH=` wins: the snapshot is replayed top to bottom,
        # so the final assignment is what the tool shell ends up with.
        _asw_snap_path=$(_asw_snap_path_of "$_asw_snap")

        if [ -z "$_asw_snap_path" ]; then
            _asw_not_checked "snapshot $_asw_snap defines no \`export PATH=\` — cannot determine the tool shell's resolution order (#652)."
        else
            # PROVENANCE: does ANY shim dir appear anywhere in the recorded
            # PATH? Presence at any position means a nexus-fronted shell
            # wrote it (order is adjudicated per name below); absence at
            # every position means the writer never had the nexus env.
            _asw_snap_has_shimdir=0
            _asw_path_has_shimdir "$_asw_snap_path" && _asw_snap_has_shimdir=1
            _asw_snap_prov="nexus-fronted (a shim dir is in its PATH)"
            [ "$_asw_snap_has_shimdir" = 1 ] || _asw_snap_prov="FOREIGN (no shim dir anywhere in its PATH)"
            # Always said, pass or not: the selection route and the
            # provenance are the two facts a reader needs after the fact,
            # and the outage's diagnostic said them only inside a refusal.
            _asw_say "NOTE: snapshot leg examined $_asw_snap — selected via: ${_asw_snap_src:-explicit NEXUS_ASSERT_SNAPSHOT}; provenance: $_asw_snap_prov."

            _asw_snap_foreign_said=0
            while IFS= read -r _asw_name; do
                [ -n "$_asw_name" ] || continue
                # First PATH entry holding an executable of this name IS what
                # the tool shell resolves — the same rule `command -v` applies.
                _asw_first=""
                _asw_oldifs=$IFS; IFS=:
                for _asw_d in $_asw_snap_path; do
                    [ -n "$_asw_d" ] || continue
                    if [ -x "$_asw_d/$_asw_name" ]; then _asw_first="$_asw_d/$_asw_name"; break; fi
                done
                IFS=$_asw_oldifs

                [ -n "$_asw_first" ] || continue   # not installed at all: not a bypass
                _asw_under_shim "$_asw_first" && continue

                if [ "$_asw_snap_has_shimdir" != 1 ]; then
                    # FOREIGN. Said once, with every name it affects listed
                    # by the per-name lines that follow.
                    if [ "$_asw_snap_foreign_said" = 0 ]; then
                        _asw_snap_foreign_said=1
                        case "$_asw_live_clean" in
                            1)
                                _asw_warned=1
                                _asw_say "WARNING: the frozen tool-shell snapshot selected above carries NO shim dir AT ALL, while this spawn's own shells resolve every guarded name correctly."
                                _asw_say "  READ AS FOREIGN, not as burial: a \`claude\` launched outside the nexus launcher (no ZDOTDIR) wrote it. It describes THAT session; the child writes its OWN snapshot from the env verified live above (your-org/nexus-code#1477)."
                                _asw_say "  NOT adjudicated as a refusal: a refusal would reach _respawn.sh and the board could not self-heal (#670/#1477) — the same rule the ambient leg applies. Errs toward ALLOWING." ;;
                            0)
                                _asw_say "NOTE: the frozen tool-shell snapshot selected above carries NO shim dir at all (FOREIGN); this spawn's OWN live probes already refused, so that refusal stands and this leg adds nothing to it." ;;
                            *)
                                _asw_not_checked "the frozen tool-shell snapshot selected above carries NO shim dir at all (FOREIGN — written by a session that never had the nexus env) AND this spawn's live probes did not run, so nothing here speaks for the child's shell (your-org/nexus-code#1477). Not a refusal on a peer's artifact; not a pass." ;;
                        esac
                    fi
                    case "$_asw_live_clean" in
                        1) _asw_say "  foreign snapshot resolves \`$_asw_name\` to '$_asw_first' — $(_asw_hazard_note "$_asw_name")" ;;
                    esac
                    continue
                fi

                # SHIM-SET DRIFT is not BURIAL (your-org/nexus-code#1477, skeptic
                # F2). The snapshot carries SOME shim dirs but not the one that
                # ships THIS name: it was recorded before that shim dir existed
                # (the orchestrator started before `monitor/newwrap` was added),
                # and the name resolves where it always did. The child's launcher
                # fronts the new dir, so nothing about the child is at risk — and
                # because the spawner's snapshot is now CARRIED into every worker
                # spawn, calling this burial would latch every spawn until the
                # orchestrator restarts. Per name: own shim dir ABSENT -> drift,
                # warn; PRESENT but behind -> burial, below.
                if ! _asw_shimdir_on_path_in "$_asw_name" "$_asw_snap_path"; then
                    _asw_warned=1
                    _asw_say "WARNING: frozen tool-shell snapshot resolves \`$_asw_name\` to '$_asw_first' and its OWN shim dir is ABSENT from that PATH while other shim dirs are present — SHIM-SET DRIFT: the snapshot predates that shim dir; not a burial. The child's launcher fronts it. (#1477 F2)"
                    continue
                fi

                # BURIAL: shim dirs ARE in the recorded PATH and this name
                # resolves ahead of them — the #578/#652/#654 signature.
                if [ "$_asw_selfheal" = 1 ]; then
                    _asw_warned=1
                    _asw_say "WARNING (self-heal path, NOT refusing): frozen tool-shell snapshot resolves \`$_asw_name\` to '$_asw_first', AHEAD of the shim dirs that ARE in its PATH — the BURIAL signature (#652/#654). $(_asw_hazard_note "$_asw_name")"
                    _asw_say "  snapshot: $_asw_snap"
                    _asw_say "  selected via: ${_asw_snap_src:-explicit NEXUS_ASSERT_SNAPSHOT}"
                    _asw_say "  NEXUS_IS_ORCHESTRATOR=1: a refusal here reaches _respawn.sh and the board cannot self-heal — measured 2026-09-06 as 1,104 failed respawns over 18 h with no path out (your-org/nexus-code#1477). Starting the orchestrator so it can repair the shell-init and write a fresh snapshot; worker spawns still refuse on this signature."
                    # One durable row per spawn, naming the first buried name;
                    # the per-name warnings above carry the rest.
                    if [ "${_asw_selfheal_recorded:-0}" = 0 ]; then
                        _asw_selfheal_recorded=1
                        _asw_record_unverified "frozen-snapshot leg: BURIAL signature (\`$_asw_name\` -> $_asw_first) in $_asw_snap [${_asw_snap_src:-explicit}] — orchestrator started ANYWAY on the self-heal path (#1477); repair shell-init and re-verify with monitor/assert-shims-wrapped.sh"
                        # The operator's tmux, not only a pane's stderr and a
                        # log row (the header promised this; skeptic F3 found
                        # it missing).
                        command -v sandbox-notify >/dev/null 2>&1 \
                            && sandbox-notify "orchestrator started BURIED (assert-shims-wrapped self-heal path, #1477): \`$_asw_name\` resolves off-shim in its tool shell — repair shell-init" >/dev/null 2>&1 || true
                    fi
                    continue
                fi
                _asw_refused=1; _asw_shim_refused=1
                _asw_say "REFUSING SPAWN: frozen tool-shell snapshot resolves \`$_asw_name\` to '$_asw_first', NOT under a shim dir. $(_asw_hazard_note "$_asw_name")"
                _asw_say "  snapshot: $_asw_snap"
                _asw_say "  selected via: ${_asw_snap_src:-explicit NEXUS_ASSERT_SNAPSHOT}"
                _asw_say "  shim dirs ARE present in that snapshot's PATH but \`$_asw_name\` resolves ahead of them — the BURIAL signature (#652/#654), not a foreign artifact (#1477)."
                _asw_say "  this is the surface the agent's Bash tool SOURCES; a fresh-shell probe repairs itself and cannot see it (#652/#654)."
            done <<EOF
${_asw_names}
EOF
        fi
    fi
fi

# ---------------------------------------------------------------------------
# RLIMIT_NPROC: observed, in self / child / grandchild.
# ---------------------------------------------------------------------------
# This is the layer that survives a bypassed shim, so it is verified by
# measurement rather than assumed from the launcher's source. Observations:
#   self       the launcher applied its ceiling before calling us, so our own
#              soft limit must not exceed NEXUS_ASSERT_NPROC_EXPECT when set.
#              This is what catches the SWALLOWED `ulimit … || true` failure.
#   child      `bash -c 'ulimit -Su'` — one exec away.
#   grandchild `bash -c 'bash -c "ulimit -Su"'` plus, when python is present,
#              `resource.getrlimit(RLIMIT_NPROC)` in a python subprocess — the
#              shape that actually matters, since the #487 storm was a re-exec
#              chain several levels below a tool shell.
# A limit may stay the same or go DOWN along the chain; an observed RISE (or a
# descendant seeing `unlimited` where we see a number) means the ceiling does
# not bound descendants and the last line of defence is not real.
_asw_nproc_num() {
    case "${1:-}" in
        unlimited|-1) printf 'unlimited' ;;
        ''|*[!0-9]*)  printf 'unknown' ;;
        *)            printf '%s' "$1" ;;
    esac
}

if [ "${NEXUS_ASSERT_SKIP_NPROC:-}" != 1 ]; then
    _asw_self=$(_asw_nproc_num "$( (ulimit -Su) 2>/dev/null )")
    _asw_child=$(_asw_nproc_num "$(bash -c 'ulimit -Su' 2>/dev/null)")
    _asw_gchild=$(_asw_nproc_num "$(bash -c 'bash -c "ulimit -Su"' 2>/dev/null)")
    _asw_expect="${NEXUS_ASSERT_NPROC_EXPECT:-}"
    _asw_nproc_bad=0
    _asw_nproc_msg=""

    # (1) Did the requested ceiling apply at all?
    case "$_asw_expect" in
        ''|0) : ;;
        *[!0-9]*) : ;;
        *)
            if [ "$_asw_self" = unlimited ]; then
                _asw_nproc_bad=1
                _asw_nproc_msg="launcher requested a soft RLIMIT_NPROC ceiling of $_asw_expect but this process sees 'unlimited' — the \`ulimit -Su\` line did not apply (its failure is swallowed by \`|| true\`), so nothing bounds a fork storm in this worker (#487)."
            elif [ "$_asw_self" = unknown ]; then
                _asw_say "WARNING: could not read this process's soft RLIMIT_NPROC — the ceiling was not verified."
                _asw_warned=1
            elif [ "$_asw_self" -gt "$_asw_expect" ] 2>/dev/null; then
                _asw_nproc_bad=1
                _asw_nproc_msg="soft RLIMIT_NPROC is $_asw_self but the launcher requested $_asw_expect — the ceiling did not apply (#487)."
            fi
            ;;
    esac

    # (2) Does it propagate? Only meaningful when we hold a finite one.
    if [ "$_asw_nproc_bad" = 0 ] && [ "$_asw_self" != unknown ] && [ "$_asw_self" != unlimited ]; then
        for _asw_gen in "child:$_asw_child" "grandchild:$_asw_gchild"; do
            _asw_glbl="${_asw_gen%%:*}"; _asw_gval="${_asw_gen#*:}"
            case "$_asw_gval" in
                unknown)
                    _asw_say "WARNING: could not read soft RLIMIT_NPROC in a spawned $_asw_glbl — propagation not verified."
                    _asw_warned=1 ;;
                unlimited)
                    _asw_nproc_bad=1
                    _asw_nproc_msg="soft RLIMIT_NPROC is $_asw_self here but 'unlimited' in a spawned $_asw_glbl — the ceiling does NOT bound descendants, so a fork storm in a tool shell is unbounded (#487)." ;;
                *)
                    if [ "$_asw_gval" -gt "$_asw_self" ] 2>/dev/null; then
                        _asw_nproc_bad=1
                        _asw_nproc_msg="soft RLIMIT_NPROC RISES from $_asw_self to $_asw_gval in a spawned $_asw_glbl — the ceiling does not bound descendants (#487)."
                    fi ;;
            esac
        done

        # The `python subprocess` leg named in #589. Absent python is a
        # WARNING, never a refusal.
        _asw_py=""
        for _asw_c in python3 python; do
            command -v "$_asw_c" >/dev/null 2>&1 && { _asw_py="$_asw_c"; break; }
        done
        if [ -n "$_asw_py" ]; then
            _asw_pyv=$(bash -c "$_asw_py -c 'import resource; print(resource.getrlimit(resource.RLIMIT_NPROC)[0])'" 2>/dev/null)
            _asw_pyv=$(_asw_nproc_num "$_asw_pyv")
            case "$_asw_pyv" in
                unlimited)
                    _asw_nproc_bad=1
                    _asw_nproc_msg="soft RLIMIT_NPROC is $_asw_self here but unlimited in a python subprocess — the ceiling does not reach python children (#487)." ;;
                unknown)
                    _asw_say "WARNING: could not read RLIMIT_NPROC from a python subprocess — that leg was not observed."
                    _asw_warned=1 ;;
                *)
                    if [ "$_asw_pyv" -gt "$_asw_self" ] 2>/dev/null; then
                        _asw_nproc_bad=1
                        _asw_nproc_msg="soft RLIMIT_NPROC RISES from $_asw_self to $_asw_pyv in a python subprocess (#487)."
                    fi ;;
            esac
        else
            _asw_say "WARNING: no python on PATH — the python-subprocess RLIMIT_NPROC leg was not observed."
            _asw_warned=1
        fi
    fi

    if [ "$_asw_nproc_bad" = 1 ]; then
        _asw_refused=1
        _asw_say "REFUSING SPAWN: $_asw_nproc_msg"
    fi
fi

# ---------------------------------------------------------------------------
# Operator-visible breadcrumbs + verdict
# ---------------------------------------------------------------------------
# A not-enforceable carve-out MUST reach the operator's emit path, not just a
# pane's stderr: a silently-unprotected spawn is exactly the "guard existed,
# nobody told anyone" failure this helper exists to prevent.
if [ "$_asw_carveout" = 1 ]; then
    command -v sandbox-notify >/dev/null 2>&1 \
        && sandbox-notify "shim CARVE-OUT: ${_asw_base} interactive spawn is warn-only (PATH-front shim bypassable; #589)" >/dev/null 2>&1 || true
    if [ -d "$_asw_root/monitor/.state" ]; then
        printf '%s\tshell=%s\twindow=%s\tsurface=login+interactive\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown-ts)" \
            "$_asw_base" "${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-unknown}}" \
            >> "$_asw_root/monitor/.state/gh-wrapper-carveout.log" 2>/dev/null || true
    fi
fi

if [ "$_asw_refused" = 1 ]; then
    # Keep the remediation specific to what actually failed — a generic
    # "the shims are broken" trailer on an nproc-only refusal would send the
    # operator to the wrong file.
    if [ "$_asw_shim_refused" = 1 ]; then
        _asw_say "one or more PATH-front guards would NOT apply in the agent's own shell."
        _asw_say "guarded names: $(printf '%s' "$_asw_names" | tr '\n' ' ')"
        _asw_say "PATH front in this env: $(printf '%s' "${PATH:-}" | tr ':' '\n' | head -4 | tr '\n' ' ')"
        _asw_say "fix: ensure monitor/shellenv/{.zshenv,.zshrc,.zprofile,.zlogin} re-front the nexus toolchain (front-path.zsh) and that locals-env.sh exported ZDOTDIR/BASH_ENV."
    else
        _asw_say "fix: check the launcher's \`ulimit -Su\` line (spawn-worker.sh's NPROC_ULIMIT_LINE / NEXUS_WORKER_NPROC_LIMIT) and the shell's hard limit — \`ulimit -Hu\`."
    fi
    command -v sandbox-notify >/dev/null 2>&1 \
        && sandbox-notify "spawn refused: PATH-front shim or nproc ceiling unverified (assert-shims-wrapped, #589)" >/dev/null 2>&1 || true
    exit 1
fi

# The third outcome, and it is checked AFTER the refusal above on purpose: a
# CONFIRMED failure outranks an unexaminable precondition. "One leg could not
# be checked and another leg FAILED" is a failure, and reporting 79 there would
# convert a refusal (78 at the launcher) into an allow-with-a-note.
if [ "$_asw_notchecked" = 1 ]; then
    _asw_say "verdict: NOT CHECKED (exit 79). This is not a pass — no statement about this host's PATH-front shims is available from this run."
    _asw_say "  the spawn is still allowed; the caller decides. NEXUS_REQUIRE_SHIM_CHECK=1 turns this into a refusal (your-org/nexus-code#612)."
    exit 79
fi

exit 0
