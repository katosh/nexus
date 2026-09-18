#!/usr/bin/env bash
# _service_root.sh — the CONTAINMENT invariant for a supervised-service
# ACTIVATION helper (`remote-up.sh` and its `*-up.sh` siblings).
# your-org/nexus-code#1034, recommendation 3: "refuse at the source".
#
#   svcroot_guard <launcher-script-dir> <nexus-root>
#     rc 0  allowed
#     rc 2  REFUSED — a stated invariant is violated (reasons on stderr)
#     rc 3  REFUSED — could not determine (fail-closed)
#
# ---------------------------------------------------------------------------
# WHY
# ---------------------------------------------------------------------------
# your-org/nexus-code#577 established that NEXUS STATE BELONGS TO THE PRIMARY,
# and fixed `spawn-worker.sh` + `ng report-init` accordingly. The SERVICE path
# was not covered. A supervised daemon started from a secondary clone produces
# a supervisor whose source path the primary's registry will never contain —
# the same shape, applied to `services.registry` instead of to reports and
# skeptic markers, and with a worse consequence: the artefact is a LIVE
# PROCESS holding a LISTENING SOCKET, not a misplaced file.
#
# There are TWO distinct failure modes here, and only the first is the one
# `#1034` reported. They need different words because the second is INVISIBLE
# to `svc.sh orphans`:
#
#   MODE A — NEXUS_ROOT UNSET.  `remote-up.sh:39` falls back to a
#     script-relative root, so registry, launcher and log ALL resolve inside
#     the clone. The primary's registry never learns the service exists;
#     `svc.sh` cannot stop what it cannot see; and the supervisor keeps itself
#     alive off the CLONE's registry (`_remote_lib.sh:_remote_registered`).
#     This is the ORPHAN of `#1034`. `svc.sh orphans` (added 2026-09-02,
#     `6f8da28`) can at least SEE it.
#
#   MODE B — NEXUS_ROOT INHERITED (the NORMAL worker case; every nexus agent
#     process has NEXUS_ROOT=<primary> exported by `locals-env.sh`).  The
#     registry resolves to the PRIMARY — but `LAUNCH_BIN` is script-relative
#     and is NOT re-rooted, so the row written into the PRIMARY registry names
#     the CLONE's launcher. Nothing is orphaned; the registry is POISONED. And
#     because the row NAMES that path, `cmd_orphans` classifies the resulting
#     supervisor as REGISTERED (`svc.sh:` the `is_reg` arm) and never reports
#     it. Delete the clone and the row points at nothing.
#
# So re-rooting NEXUS_ROOT alone — the `#577` remedy — does not fix mode B:
# the launcher path has to be inside the root it is being registered under.
# That is the invariant this file states, and it covers both modes:
#
#   R1 IDENTITY     the launcher tree must BE $NEXUS_ROOT, not merely be
#                   inside it. "Inside" is the rule a first draft reaches for
#                   and it is the one that lets mode B through: a secondary
#                   clone lives at `<primary>/work/<clone>`, which IS inside
#                   the primary. Measured — the draft of this file allowed all
#                   three of {primary, mode A, mode B}. Identity refuses B.
#   R2 PRIMACY      $NEXUS_ROOT must not ITSELF be a secondary clone, i.e. must
#                   not sit at `<A>/work/…` for a nexus root A. Mode A satisfies
#                   R1 by construction (root and launcher are the same clone),
#                   so R1 alone cannot see it; this is the rule that does.
#   R3 DURABILITY   neither may sit in an EPHEMERAL directory (/tmp, /var/tmp,
#                   $TMPDIR). "Starting a daemon from a /tmp scratchpad should
#                   be impossible, not merely unwise" — and /tmp does not
#                   survive a sandbox restart, so such a supervisor is an
#                   orphan the moment its own code is deleted underneath it.
#                   This is not theoretical: at the time of writing,
#                   `svc.sh orphans` reports a live ppid-1 supervisor at
#                   /tmp/w215jup.NvHM0G/monitor/labsh-supervised.sh.
#
# ---------------------------------------------------------------------------
# REFUSE, NOT RE-ROOT — and why this differs from spawn-worker.sh
# ---------------------------------------------------------------------------
# `spawn-worker.sh` re-roots silently-but-loudly because a worker still WORKS
# in the clone; only its state moves. There is no equivalent here. Re-rooting
# would mean running the PRIMARY's supervisor code when the operator invoked
# the CLONE's — a different binary, binding a real socket, under a name the
# operator will later `svc.sh restart`. Refusing cannot start the wrong thing;
# re-rooting can. For an activation verb the safe direction is to decline and
# name the command that would be correct.
#
# `NEXUS_ALLOW_SECONDARY_ROOT=1` is the override, deliberately the SAME knob
# `spawn-worker.sh` uses so the workspace has one. It is applied AFTER every
# rule has been evaluated and PRINTED, not as an early return — so an operator
# who overrides still reads exactly what they overrode. (`spawn-worker.sh`
# takes the early-return form; this is the better of the two and the reason is
# in CLAUDE.md's allowlist-doctrine entry: a SAFE arm that returns before the
# DENY arms makes the DENY arms unreachable, and here they carry the only
# diagnosis the operator has.)
#
# READ-ONLY VERBS ARE NOT GATED. `--status`, `--port` and `--down` never
# create a supervisor; `--down` in particular is the RETIREMENT path and must
# keep working from anywhere, or this guard would strand exactly the state it
# exists to prevent.

# Physical path of $1, or empty if no such directory. `CDPATH=` is load-bearing
# — an operator CDPATH makes a relative `cd` resolve against a search path
# (spawn-worker.sh carries the same precaution and the same reason).
_svcroot_realpath() { (CDPATH= cd "${1:-/nonexistent}" 2>/dev/null && pwd -P); }

# Is path $1 inside directory $2, or equal to it? Both must be physical paths.
_svcroot_under() {
    local p="${1:-}" d="${2:-}"
    [ -n "$p" ] && [ -n "$d" ] || return 1
    [ "$p" = "$d" ] && return 0
    case "$p" in "$d"/*) return 0 ;; esac
    return 1
}

# Is $1 a plausible nexus root? Same predicate as spawn-worker.sh's
# `_sw_root_is_nexus`, kept identical on purpose: two different answers to
# "is this a nexus root?" in one workspace is its own defect.
_svcroot_is_nexus() {
    [ -n "${1:-}" ] && [ -d "$1" ] && [ -x "$1/monitor/spawn-worker.sh" ] && [ -d "$1/config" ]
}

# The ephemeral roots. $TMPDIR is included only when it is absolute and is not
# `/` — a TMPDIR of `/` would make every path on the host "ephemeral", which is
# the over-matching direction and would refuse a correct primary.
_svcroot_ephemeral_dirs() {
    local d
    for d in /tmp /var/tmp "${TMPDIR:-}"; do
        [ -n "$d" ] || continue
        case "$d" in /) continue ;; /*) ;; *) continue ;; esac
        d=$(_svcroot_realpath "$d") || continue
        [ -n "$d" ] && printf '%s\n' "$d"
    done | sort -u
}

# Walk up from $1 looking for an ancestor A such that $1 sits at `A/work/…` and
# A is itself a plausible nexus root. That relation IS the definition of a
# secondary clone in this workspace (CLAUDE.md: `git clone … work/<project>`).
# Diagnostic only: it NAMES the primary in the refusal so the operator has the
# command to run. It is never a licence to proceed.
_svcroot_primary_of() {
    local cand="${1:-}"
    [ -n "$cand" ] || return 1
    while :; do
        case "$cand" in */work/*) : ;; *) return 1 ;; esac
        cand="${cand%/work/*}"
        [ -n "$cand" ] || return 1
        if _svcroot_is_nexus "$cand" && [ "$cand" != "$1" ]; then
            printf '%s' "$cand"; return 0
        fi
    done
}

# svcroot_guard <launcher-script-dir> <nexus-root>
svcroot_guard() {
    local script_dir="${1:-}" root_in="${2:-}"
    local tag="${SVCROOT_TAG:-svcroot}"

    if [ -z "$script_dir" ] || [ -z "$root_in" ]; then
        echo "$tag: REFUSED — svcroot_guard needs <script-dir> <nexus-root>; got '${script_dir}' '${root_in}'." >&2
        return 3
    fi

    # The launcher's own tree root = the parent of its monitor/ dir.
    local script_root_rp root_rp
    script_root_rp=$(_svcroot_realpath "$script_dir/..")
    root_rp=$(_svcroot_realpath "$root_in")

    # FAIL-CLOSED. A path we cannot resolve is not a path we may vouch for:
    # "could not tell" must never degrade into "no violation found".
    if [ -z "$script_root_rp" ] || [ -z "$root_rp" ]; then
        echo "$tag: REFUSED — could not resolve a physical path, so containment cannot be" >&2
        echo "$tag:   established. launcher tree: '${script_root_rp:-<unresolvable: $script_dir/..>}'" >&2
        echo "$tag:   NEXUS_ROOT: '${root_rp:-<unresolvable: $root_in>}'" >&2
        return 3
    fi

    # ---- SCOPE: an EXPLICIT registry path takes this guard out of scope ------
    # Every rule below is about an INFERRED registry location. `_remote_services_registry`
    # resolves `$NEXUS_SERVICES_REGISTRY` -> `$NEXUS_ROOT/monitor/services.registry` ->
    # script-relative (`_remote_lib.sh`), and BOTH hazard modes come from the
    # second and third arms — the caller did not say where the row goes, so it
    # goes somewhere derived from a root that may not be the operator's. When
    # the caller NAMES the registry, there is no inference left to get wrong:
    # the row lands exactly where they said, and the supervisor's own
    # `_remote_registered` gate reads that same explicit path first, so writer
    # and reader agree by construction.
    #
    # This is what every hermetic harness in monitor/watcher/ does
    # (`export NEXUS_SERVICES_REGISTRY=$WORK/services.registry` beside a temp
    # `NEXUS_ROOT`), and what an operator enabling a real endpoint never does.
    # Without this, seven `test-remote-*` suites go red — measured:
    # `test-remote-service.sh` fell to 59/6, every failure "no registry row".
    #
    # UNLIKE THE OVERRIDE AT THE FOOT OF THIS FUNCTION, THIS ONE RETURNS EARLY,
    # and the difference is not convenience. The override SUPPRESSES violations
    # that genuinely apply, so it must print them first (CLAUDE.md's
    # allowlist-doctrine entry: a SAFE arm before a DENY arm). This is a SCOPE
    # statement — the rules do not apply, so there is no diagnosis to withhold,
    # and emitting REFUSED lines into a passing test run would be noise a
    # harness may well assert against. It is announced, never silent.
    if [ -n "${NEXUS_SERVICES_REGISTRY:-}" ]; then
        echo "$tag: note: NEXUS_SERVICES_REGISTRY is set explicitly (${NEXUS_SERVICES_REGISTRY:-}) —" >&2
        echo "$tag:   the root-containment guard is about INFERRED registry location and does not" >&2
        echo "$tag:   apply. The row goes where you named it." >&2
        return 0
    fi

    # ---- evaluate EVERY rule before deciding, so the report is complete ----
    local violated=0

    # R1 IDENTITY — the launcher tree must BE $NEXUS_ROOT. Equality, not
    # containment: a secondary clone at `<primary>/work/<clone>` is CONTAINED
    # in the primary, so a containment test passes it (measured) and mode B
    # walks straight through.
    local primary
    if [ "$script_root_rp" != "$root_rp" ]; then
        violated=1
        echo "$tag: REFUSED — R1 IDENTITY: this launcher is not the one that lives in \$NEXUS_ROOT." >&2
        echo "$tag:   Every row written below names THIS tree's supervisor, so the registry would" >&2
        echo "$tag:   point at a launcher \$NEXUS_ROOT does not own — and the primary could neither" >&2
        echo "$tag:   supervise nor retire it once this tree is gone." >&2
        echo "$tag:     launcher tree : $script_root_rp" >&2
        echo "$tag:     NEXUS_ROOT    : $root_rp" >&2
        if primary=$(_svcroot_primary_of "$script_root_rp"); then
            echo "$tag:   This launcher is a SECONDARY CLONE under $primary/work (your-org/nexus-code#577)." >&2
        fi
        echo "$tag:   Run the copy that lives in \$NEXUS_ROOT:" >&2
        echo "$tag:     $root_rp/monitor/${SVCROOT_VERB:-<up-script>}" >&2
    fi

    # R2 PRIMACY — $NEXUS_ROOT must not itself be a secondary clone. Mode A
    # (NEXUS_ROOT unset, so it falls back to this very clone) satisfies R1 by
    # construction; without this rule it is invisible.
    if primary=$(_svcroot_primary_of "$root_rp"); then
        violated=1
        echo "$tag: REFUSED — R2 PRIMACY: \$NEXUS_ROOT is itself a SECONDARY CLONE." >&2
        echo "$tag:     NEXUS_ROOT: $root_rp" >&2
        echo "$tag:     primary   : $primary" >&2
        echo "$tag:   Nexus STATE belongs to the primary (your-org/nexus-code#577), and a service" >&2
        echo "$tag:   registered here is invisible to it: \`svc.sh\` reads the PRIMARY registry, so" >&2
        echo "$tag:   nothing there can stop what is started here. Run:" >&2
        echo "$tag:     $primary/monitor/${SVCROOT_VERB:-<up-script>}" >&2
    fi

    # Collected into a variable first: a `cmd | while` would run the loop in a
    # SUBSHELL, where `violated=1` is written and then discarded — the loop
    # would report every refusal on stderr and still return 0. A here-STRING
    # redirect keeps the loop in this shell; the assignment is why the shape
    # matters, not the loop.
    local eph _eph_list
    _eph_list=$(_svcroot_ephemeral_dirs)
    while IFS= read -r eph; do
        [ -n "$eph" ] || continue
        if _svcroot_under "$root_rp" "$eph"; then
            violated=1
            echo "$tag: REFUSED — R3 DURABILITY: NEXUS_ROOT is inside the EPHEMERAL directory $eph." >&2
            echo "$tag:     NEXUS_ROOT: $root_rp" >&2
            echo "$tag:   A supervised daemon outlives the shell that started it; this tree does not" >&2
            echo "$tag:   survive a sandbox restart, and deleting it strands a live listener whose own" >&2
            echo "$tag:   code is gone. See it with: monitor/svc.sh orphans" >&2
        fi
        if [ "$script_root_rp" != "$root_rp" ] && _svcroot_under "$script_root_rp" "$eph"; then
            violated=1
            echo "$tag: REFUSED — R3 DURABILITY: the launcher tree is inside the EPHEMERAL directory $eph." >&2
            echo "$tag:     launcher tree: $script_root_rp" >&2
        fi
    done <<< "$_eph_list"

    if (( violated == 0 )); then return 0; fi

    # The override is applied HERE — after every rule has spoken — so the
    # operator who sets it still reads the full diagnosis above.
    if [ "${NEXUS_ALLOW_SECONDARY_ROOT:-}" = 1 ]; then
        echo "$tag: OVERRIDDEN by NEXUS_ALLOW_SECONDARY_ROOT=1 — proceeding despite the refusal(s)" >&2
        echo "$tag:   above. You are knowingly creating a supervisor the primary may not be able to" >&2
        echo "$tag:   retire. Retire it yourself before this tree goes away." >&2
        return 0
    fi

    echo "$tag: nothing was registered, started or changed. Override (knowingly):" >&2
    echo "$tag:   NEXUS_ALLOW_SECONDARY_ROOT=1 <your command>" >&2
    return 2
}
