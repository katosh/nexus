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
#   1  CONFIRMED failure. The launcher must abort the spawn.
#  79  NOT CHECKED — the guard's own precondition is absent (NEXUS_ROOT unset,
#      no shim dirs, probe shell missing). Never folded into 0. A CONFIRMED
#      failure outranks it: if any leg refuses, the verdict is 1, because
#      "part of this could not be checked and part of it FAILED" is a failure.
#
# Overrides (for tests):
#   NEXUS_SHIMWRAP_GLOB       shim-dir glob (default $NEXUS_ROOT/monitor/*wrap)
#   NEXUS_ASSERT_GH_SHELL     shell to probe (default $SHELL, then /usr/bin/zsh)
#   NEXUS_ASSERT_NPROC_EXPECT expected soft RLIMIT_NPROC (the launcher's
#                             ceiling). Unset/0 → propagation is still observed,
#                             but no specific ceiling is required.
#   NEXUS_ASSERT_SKIP_NPROC=1 skip the nproc observation entirely.
#   NEXUS_ASSERT_SKIP_SHIMS=1 skip the shim-reachability probes entirely.

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
    if command -v timeout >/dev/null 2>&1; then
        timeout 40 "$_asw_probe_shell" $_asw_flags "$_asw_cmd" 2>/dev/null \
            | sed -n 's/^SHIMMARK://p'
    else
        "$_asw_probe_shell" $_asw_flags "$_asw_cmd" 2>/dev/null \
            | sed -n 's/^SHIMMARK://p'
    fi
    rm -f "$ZSH_COMPDUMP" 2>/dev/null || true
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
    for _asw_spec in \
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
                _asw_say "WARNING: $_asw_base $_asw_lbl: \`$_asw_name\` did not resolve at all (empty). Not a hazard on its own (a missing command fails loudly on use), so allowing — but the shim is not on PATH here."
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
                    # That is a bypass by another route — a confirmed-bad
                    # state, not an unknown one.
                    _asw_msg="\`$_asw_name\` is SHADOWED by a shell alias/function ('$_asw_res') ahead of the shim. $(_asw_hazard_note "$_asw_name")"
                    ;;
            esac

            if [ "$_asw_enf" = 1 ]; then
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
        if command -v timeout >/dev/null 2>&1; then
            timeout 40 "$_asw_probe_shell" -c 'printf "GHVERMARK:%s\n" "$(gh --version 2>/dev/null | head -1)"' 2>/dev/null
        else
            "$_asw_probe_shell" -c 'printf "GHVERMARK:%s\n" "$(gh --version 2>/dev/null | head -1)"' 2>/dev/null
        fi | sed -n 's/^GHVERMARK://p' | head -1
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
