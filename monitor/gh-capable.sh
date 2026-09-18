# shellcheck shell=sh
# monitor/gh-capable.sh — the DECLARED MINIMUM `gh` version, and the resolution
# primitive that prefers a client meeting it (your-org/nexus-code#755).
#
# SOURCE this (do not execute).
#
# ---------------------------------------------------------------------------
# WHY THIS FILE EXISTS
# ---------------------------------------------------------------------------
# `monitor/ghwrap/gh` resolved the real client as "the first `gh` on PATH that
# is not THIS wrapper". That criterion is IDENTITY (not-the-wrapper) being
# asked to carry a CAPABILITY guarantee it never made. FIVE clients are
# installed on this host, spanning 1.3.1 to 2.89.0 (full table below), and
# which one wins is decided by PATH order — an accident of shell-init
# sequencing, not a choice. The one the operator's shells actually reached was
# /app/bin/gh 1.13.0 (2021-07-20), from the agent-sandbox base image.
#
# Measured 2026-08-07 against your-org/nexus-code with the SAME bot token, that
# client degrades SILENTLY on the surfaces this repo's CI-verdict discipline
# depends on:
#
#   gh run view --job <id> --log   rc=0, ZERO lines      (2.89.0: 622 lines)
#   gh run view <run> --log        rc=0, 2 of 10 JOBS    (2.89.0: all 10)
#
# AND A CAPABLE CLIENT IS NOT ENOUGH FOR THAT FIRST FORM (your-org/nexus-code#1408):
# on 2.89.0, `gh run view --job <id> --log` IGNORES the job id and serves the
# run's LATEST attempt — a failing attempt-1 job read `0 failed`, byte-identical
# to attempt 2. This floor buys correct `pr checks` and complete `run view
# <run> --log`; per-job, per-attempt log bodies come ONLY from
# `gh api repos/O/R/actions/jobs/<id>/logs`. A log byte count is
# method-dependent (`run view` prefixes job/step names, ~80% larger) — tag it.
#   gh pr checks                   prints `pass` for a check whose REST
#                                  conclusion is `skipped`
#
# The middle one is the worst of the three: it is not empty, it is a
# plausible-looking 1456-line log that silently omits eight of ten jobs. The
# third is a verdict MISREPORT — `#628`/`#740` exist precisely to stop
# `skipped` and `cancelled` being read as success, and the stale client
# launders one into the other before the enumeration ever sees it.
#
# ---------------------------------------------------------------------------
# THE FLOOR IS A PROXY, AND SAYING SO IS THE POINT
# ---------------------------------------------------------------------------
# `#755` is an issue about identity standing in for capability. A version
# number is ALSO an identity claim ("I am 2.89.0"), not a demonstration of
# capability — so a naive version floor recommits the very substitution the
# issue names, one level up. Two things keep this honest:
#
#   1. The floor is LICENSED BY A MEASURED TABLE (below, and the divergence
#      matrix in the `#755` thread), not by reading a changelog — and when the
#      table grew from two clients to five it MOVED the floor, which is what a
#      licensed number is supposed to do.
#
#   2. It is the RIGHT proxy anyway, because the alternative that LOOKS more
#      like capability is blind to the headline defect. Probing `--help` for
#      the flag is a genuine capability test — and every one of these clients
#      advertises `run view --log`, including the two that return nothing and
#      the two that truncate:
#
#        /app/bin/gh run view --help  →  "--log   View full log for either a
#                                         run or specific job"
#
#      The stale client ACCEPTS the flag, exits 0, and writes nothing. So
#      help-text probing cannot see the ADVERTISED-BUT-BROKEN class, which is
#      the entire silent half of `#755`. Only a version floor covers it.
#
#      This file USED to carry a `_ghc_probe_help` helper "for the loud,
#      absent-surface class". It was deleted, and why is worth recording. Its
#      body was `"$1" ${2:+} --help >/dev/null 2>&1` — `${2:+}` expands to the
#      empty string unconditionally and the output went to /dev/null, so the
#      needle was never searched for. It returned 0 for a deliberately bogus
#      needle on every client tried. It answered "does `gh --help` exit 0",
#      which is IDENTITY, not capability: the exact substitution `#755` names,
#      sitting in the file whose header argues against it, under a contract
#      claiming it did the opposite. Nothing called it. A capability probe that
#      cannot fail is worse than no probe, because the header vouched for it —
#      so it is gone rather than repaired (skeptic finding F1).
#
# ---------------------------------------------------------------------------
# THE COVERAGE BOUNDARY, ON THE AXIS THE MECHANISM VARIES ON
# ---------------------------------------------------------------------------
# The axis is `gh` VERSION, not subcommand spelling. FIVE clients are installed
# on this host and ALL FIVE were measured against the same 10-job run
# (your-org/nexus-code run 31172272010), counting how many of its jobs
# `run view --log` actually returns:
#
#   /app/software/gh/1.3.1     "gh version DEV"    0 of 10 jobs   + no `pr checks` output
#   /app/bin/gh                1.13.0              2 of 10 jobs   + `pass` for a SKIPPED check
#   /app/software/gh/2.14.7    "gh version DEV"    2 of 10 jobs   + correct `pr checks`
#   /app/software/gh/2.86.0    2.86.0             10 of 10 jobs
#   ~/.linuxbrew/bin/gh        2.89.0             10 of 10 jobs
#
# THE FIRST DRAFT OF THIS FILE SET THE FLOOR AT 2.0.0 AND WAS WRONG. It was
# written when only two clients had been found, and "1.x bad, 2.x good" is the
# boundary two points suggest. The 2.14.7 row refutes it: the log truncation is
# NOT a 1.x defect, and a 2.0.0 floor would have VOUCHED for a client that
# returns two of ten jobs — issuing exactly the false capability guarantee this
# file exists to stop. A bound drawn on too little of the axis is honest,
# tested, and false.
#
# So the floor is `2.86.0`: the OLDEST version measured CORRECT here.
#   * measured BAD:        <= 2.14.7
#   * measured GOOD:       >= 2.86.0
#   * UNMEASURED GAP:      2.15 … 2.85  — no client in that range exists on
#                          this host and none can be fetched from inside the
#                          sandbox, so nothing is known about it.
#
# The gap is excluded rather than admitted, and the asymmetry is the reason:
# being too strict costs a WARNING on a client that may well be fine, while
# being too lax silently vouches for one that truncates. Wrongly vouching is
# the #755 defect itself. A fork whose host carries an unmeasured-but-working
# client gets a warning, never a refusal, and can set `NEXUS_GH_MIN_VERSION`
# to whatever its own measurements license.
#
# THE `DEV` ROWS ARE WHY `unverified` EXISTS. Two of these builds report
# `gh version DEV` — no parseable number at all — and they sit at OPPOSITE ends
# of the capability range (1.3.1 returns nothing; 2.14.7 truncates). That is the
# version proxy failing outright, in the wild, on this host. Such a client is
# taken IN PLACE (see `_ghc_resolve`) and reported `unverified`; the spawn gate
# is what says so out loud, once per spawn.
#
# ---------------------------------------------------------------------------
# AVAILABILITY: WHY THIS PRIMITIVE NEVER REFUSES
# ---------------------------------------------------------------------------
# This file only ANSWERS QUESTIONS — it never exits and never refuses. The
# wrapper that consumes it degrades to today's behaviour (first non-self `gh`)
# plus a loud, durable warning when no candidate meets the floor, because
# `monitor/ghwrap/gh` is on the path of every agent AND the watcher, and a
# wrapper that starts refusing mid-flight halts a nexus that cannot be
# restarted. PR `#670` documents that blast radius for the sibling gate; the
# same reasoning binds here. Enforcement belongs at the SPAWN gate
# (`assert-shims-wrapped.sh`), where a refusal is a controlled event.
#
# Overrides:
#   NEXUS_GH_MIN_VERSION      floor, "M.m.p" (default 2.86.0 — see the
#                             coverage-boundary section above before lowering it)
#   NEXUS_GH_CAPABLE_NOCACHE  =1 to bypass the version cache (tests)
#   NEXUS_GH_CAPABLE_CACHE    cache dir (default $NEXUS_STATE_DIR/gh-capable.d, else
#                             $NEXUS_ROOT/monitor/.state/gh-capable.d — #1453)

_ghc_floor() { printf '%s' "${NEXUS_GH_MIN_VERSION:-2.86.0}"; }

# --- realpath helper (same shape as ghwrap/gh's `_gw_rp`) --------------------
_ghc_rp() {
    if readlink -f / >/dev/null 2>&1; then
        readlink -f "$1" 2>/dev/null && return 0
    fi
    _ghc_rp_d=$(CDPATH= cd "$(dirname "$1")" 2>/dev/null && pwd) || return 1
    printf '%s/%s\n' "$_ghc_rp_d" "$(basename "$1")"
}

# --- cache ------------------------------------------------------------------
# One small file per binary, named after its path, holding `size mtime version`.
# One file per key + atomic rename means no locking is needed when a dozen
# agents probe concurrently. Keyed on size AND mtime so an in-place upgrade
# (brew relinking gh) invalidates instead of serving a stale answer — the cache
# must never become its own version of the bug this file fixes.
# THE CACHE IS STATE, AND IT RESOLVES LIKE STATE (your-org/nexus-code#1453):
# NEXUS_GH_CAPABLE_CACHE -> NEXUS_STATE_DIR -> NEXUS_ROOT/monitor/.state — the
# same arm order as `ng`'s `_resolve_state_dir`, minus the config arm (this
# file must stay dependency-free; a wrong cache dir here costs one re-probe,
# not a lost write). It used to consult only NEXUS_ROOT, so a suite that had
# pinned NEXUS_STATE_DIR to its own scratch — the prescribed hermeticity
# spelling — still wrote `gh-capable.d/` into the INHERITED root the moment any
# child reached `gh` through the PATH-front wrapper. Measured on two suites
# under `nexus-root-sensitivity.sh probe`: LEAK rc=0 on an operator's host,
# hermetic on CI, because CI has no BASH_ENV force-fronting the wrapper ahead
# of the suite's stub. An instrument that answers differently on two hosts
# has an unenumerated input; this arm is that input, enumerated.
_ghc_cache_dir() {
    if [ -n "${NEXUS_GH_CAPABLE_CACHE:-}" ]; then printf '%s' "$NEXUS_GH_CAPABLE_CACHE"; return 0; fi
    if [ -n "${NEXUS_STATE_DIR:-}" ]; then printf '%s' "$NEXUS_STATE_DIR/gh-capable.d"; return 0; fi
    [ -n "${NEXUS_ROOT:-}" ] || return 1
    printf '%s' "$NEXUS_ROOT/monitor/.state/gh-capable.d"
}

_ghc_cache_key() {
    # path → filename-safe token
    printf '%s' "$1" | tr '/' '%' | tr -c 'A-Za-z0-9%._-' '_'
}

_ghc_stat() {
    # echo "<size> <mtime>"; empty when unavailable (non-GNU stat, missing file)
    stat -c '%s %Y' -- "$1" 2>/dev/null && return 0
    stat -f '%z %m' -- "$1" 2>/dev/null && return 0
    printf ''
}

# --- version -----------------------------------------------------------------
# `_ghc_raw_version <bin>` → "M.m.p" on stdout, empty when it could not be read.
# Parses `gh version 2.89.0 (2026-03-26)`; tolerates `2.4.0+dev` style suffixes.
_ghc_raw_version() {
    _ghc_v=$("$1" --version 2>/dev/null | head -1 | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^v?[0-9]+\.[0-9]+/) { print $i; exit } }')
    _ghc_v="${_ghc_v#v}"
    # strip anything after the patch component (+dev, -rc1, …)
    _ghc_v=$(printf '%s' "$_ghc_v" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\).*$/\1/p')
    printf '%s' "$_ghc_v"
}

# `_ghc_version <bin>` → cached "M.m.p", empty when undeterminable.
_ghc_version() {
    _ghc_bin="$1"
    [ -n "$_ghc_bin" ] && [ -x "$_ghc_bin" ] || { printf ''; return 0; }

    if [ "${NEXUS_GH_CAPABLE_NOCACHE:-}" = 1 ]; then
        _ghc_raw_version "$_ghc_bin"; return 0
    fi

    _ghc_real=$(_ghc_rp "$_ghc_bin" 2>/dev/null || printf '%s' "$_ghc_bin")
    _ghc_st=$(_ghc_stat "$_ghc_real")
    _ghc_dir=$(_ghc_cache_dir 2>/dev/null || printf '')

    if [ -n "$_ghc_dir" ] && [ -n "$_ghc_st" ]; then
        _ghc_f="$_ghc_dir/$(_ghc_cache_key "$_ghc_real")"
        if [ -r "$_ghc_f" ]; then
            _ghc_line=$(cat "$_ghc_f" 2>/dev/null)
            # "<size> <mtime> <version>" — accept only on an exact stat match
            case "$_ghc_line" in
                "$_ghc_st "*)
                    printf '%s' "${_ghc_line#"$_ghc_st" }"
                    return 0 ;;
            esac
        fi
    fi

    _ghc_ver=$(_ghc_raw_version "$_ghc_bin")

    # Write-through. Every failure here is non-fatal: the cache is a latency
    # optimisation, and losing it costs one exec, never a wrong answer.
    if [ -n "$_ghc_dir" ] && [ -n "$_ghc_st" ] && [ -n "$_ghc_ver" ]; then
        if mkdir -p "$_ghc_dir" 2>/dev/null; then
            _ghc_tmp="$_ghc_dir/.tmp.$$.$(_ghc_cache_key "$_ghc_real")"
            if printf '%s %s\n' "$_ghc_st" "$_ghc_ver" > "$_ghc_tmp" 2>/dev/null; then
                mv -f "$_ghc_tmp" "$_ghc_dir/$(_ghc_cache_key "$_ghc_real")" 2>/dev/null \
                    || rm -f "$_ghc_tmp" 2>/dev/null || true
            else
                rm -f "$_ghc_tmp" 2>/dev/null || true
            fi
        fi
    fi
    printf '%s' "$_ghc_ver"
}

# `_ghc_ge <a> <b>` → rc 0 when version a >= version b. Pure string/number
# compare, no `sort -V` (absent on some minimal images, and its tie-breaking on
# malformed input is not worth inheriting).
_ghc_ge() {
    _ghc_a="$1"; _ghc_b="$2"
    [ -n "$_ghc_a" ] && [ -n "$_ghc_b" ] || return 1
    _ghc_i=1
    while [ "$_ghc_i" -le 3 ]; do
        _ghc_x=$(printf '%s' "$_ghc_a" | cut -d. -f"$_ghc_i"); _ghc_x=${_ghc_x:-0}
        _ghc_y=$(printf '%s' "$_ghc_b" | cut -d. -f"$_ghc_i"); _ghc_y=${_ghc_y:-0}
        case "$_ghc_x" in ''|*[!0-9]*) _ghc_x=0 ;; esac
        case "$_ghc_y" in ''|*[!0-9]*) _ghc_y=0 ;; esac
        [ "$_ghc_x" -gt "$_ghc_y" ] && return 0
        [ "$_ghc_x" -lt "$_ghc_y" ] && return 1
        _ghc_i=$((_ghc_i + 1))
    done
    return 0   # equal
}

# `_ghc_meets <bin>` → 0 meets the floor, 1 below it, 2 UNDETERMINABLE.
#
# THREE states, not two, and 2 is never folded into either neighbour — the same
# contract `assert-shims-wrapped.sh` draws at exit 79 (`#612`). "I could not
# read this client's version" is not "it is fine" and not "it is stale"; a
# caller that cannot tell must be able to say so.
# Side effect BY DESIGN: the version it read is left in `_ghc_last_ver` (empty
# when undeterminable). `_ghc_resolve` reports the version of whatever it
# chose or skipped, and re-probing to obtain a number this call already has is
# a fork per candidate on a path that runs for every `gh` invocation.
_ghc_last_ver=""
_ghc_meets() {
    _ghc_last_ver=$(_ghc_version "$1")
    [ -n "$_ghc_last_ver" ] || return 2
    if _ghc_ge "$_ghc_last_ver" "$(_ghc_floor)"; then return 0; fi
    return 1
}

# `_ghc_is_ghwrap <path>` → 0 when this candidate is a nexus gh wrapper.
#
# Not a self-check (the wrapper already excludes itself by realpath) but a
# CROSS-CLONE one. This workspace's standing convention is independent clones
# under `work/<project>-<task>/`, each carrying its own `monitor/ghwrap/gh`, and
# a worker's PATH can carry a sibling clone's wrapper dir. Probing that with
# `--version` would exec a whole second wrapper — terminating, but it would
# attribute the WRONG version (the sibling's resolution, not ours) to a
# candidate slot. Skip anything living in a `*/ghwrap/` directory.
#
# THE PATH-SHAPE TEST IS NOT SUFFICIENT ON ITS OWN, AND THAT WAS MEASURED
# (your-org/nexus-code#1033). Both arms below key on the literal directory name
# `ghwrap`, which is IDENTITY BY LOCATION — the same substitution `#755` names,
# one level up. A copy of the wrapper in a directory called anything else passes
# both arms, and the capability floor does NOT catch it: a wrapper copy probed
# with `--version` DELEGATES to its own real gh and reports that version, so it
# reads as fully capable. Measured with two copies in dirs named `ghshim`:
# unbounded FORK growth, 43 processes in 5 seconds.
#
# So ask what the candidate IS. A real `gh` is an ELF binary; every copy of the
# wrapper is a shell script carrying its own self-identifying path comment in
# the first lines — present in every revision, so it needs no cooperation from
# the copy being examined (a marker introduced by a fix is an opt-in that only
# the ALREADY-FIXED copy carries, which is useless during a rollout).
#
# Forkless: `read` is a builtin and a redirect on a builtin does not fork. A
# real gh is not `#!`, so it costs one 2-byte read and never the line scan.
_ghc_is_ghwrap() {
    case "$1" in
        */ghwrap/gh) return 0 ;;
    esac
    _ghc_wr=$(_ghc_rp "$1" 2>/dev/null || printf '')
    case "$_ghc_wr" in
        */ghwrap/gh) return 0 ;;
    esac
    # Content gate — independent of where the file happens to live.
    IFS= read -r -N 2 _ghc_magic < "$1" 2>/dev/null || return 1
    [ "$_ghc_magic" = '#!' ] || return 1
    _ghc_scan=0
    while [ "$_ghc_scan" -lt 40 ] && IFS= read -r _ghc_line; do
        case "$_ghc_line" in
            *monitor/ghwrap/gh*) return 0 ;;
        esac
        _ghc_scan=$((_ghc_scan + 1))
    done < "$1"
    return 1
}

# ---------------------------------------------------------------------------
# `_ghc_resolve <self-realpath> <PATH>` — the resolution primitive.
# ---------------------------------------------------------------------------
# Emits ONE line:  <chosen-binary>\t<status>\t<chosen-version>\t<skipped-list>
#
#   status=ok          a candidate met the floor and was chosen
#   status=unverified  the first candidate's version could not be read; it is
#                      taken IN PLACE anyway. The floor demotes only on
#                      POSITIVE proof of being too old — never on a silence,
#                      because stepping over an unreadable client would change
#                      which binary runs on absence of evidence.
#   status=degraded    every candidate was PROVEN below the floor; the first
#                      one is chosen anyway (availability over refusal)
#   status=none        no `gh` on PATH at all besides the wrapper
#
# <skipped-list> is comma-separated `path@version` for every candidate passed
# over, so the caller can name what it rejected instead of asserting a bare
# "something was wrong". Empty when nothing was skipped.
#
# PATH order is preserved: the FIRST candidate meeting the floor wins, so a
# deliberately-fronted client still takes precedence over a later one. Probing
# stops at that candidate — on a host whose first candidate is capable this
# costs a single cached stat, not a version exec per entry.
#
# ---------------------------------------------------------------------------
# COST, and why the WHOLE resolution is memoised rather than each version
# ---------------------------------------------------------------------------
# This runs on EVERY `gh` call by every agent and the watcher, so its cost is
# not academic. A per-binary version cache still paid ~6 forks per candidate
# (realpath, stat, the key transform, the read) and measured **344 ms/call**
# warm on this host — unacceptable next to an old resolution that forked once
# or twice. The unit that is actually stable is the whole ANSWER, so the whole
# answer is what gets cached, keyed on the exact PATH string it was computed
# for. Warm cost is one `stat` (~2 ms): the scan itself is a `while read` over
# a small file and forks nothing.
#
# TWO deliberate staleness decisions:
#   * Only the CHOSEN binary is re-stat'd, not every candidate. A capable
#     client appearing EARLIER on an unchanged PATH is therefore not noticed
#     until the cache line is displaced — benign, because the cached answer is
#     still a capable client.
#   * `degraded` answers are NEVER cached. That is the case where the host is
#     wrong and where noticing an improvement matters, so it re-resolves every
#     call. It is also the rare path, so the cost lands where it is affordable.
_ghc_cache_lines=12      # PATH variants retained; a bound, not a tuning knob

_ghc_resolve() {
    _ghc_self="${1:-}"
    _ghc_path="${2:-$PATH}"

    _ghc_rfile=""
    if [ "${NEXUS_GH_CAPABLE_NOCACHE:-}" != 1 ]; then
        _ghc_rdir=$(_ghc_cache_dir 2>/dev/null || printf '')
        [ -n "$_ghc_rdir" ] && _ghc_rfile="$_ghc_rdir/resolved"
    fi

    # --- warm path: scan for a line computed for this exact PATH -------------
    if [ -n "$_ghc_rfile" ] && [ -r "$_ghc_rfile" ]; then
        _ghc_tab=$(printf '\t')
        while IFS="$_ghc_tab" read -r _ghc_kp _ghc_kc _ghc_ks _ghc_kv _ghc_kst; do
            [ "$_ghc_kp" = "$_ghc_path" ] || continue
            [ -n "$_ghc_kc" ] && [ -x "$_ghc_kc" ] || break
            # the chosen binary must be byte-for-byte the one we vouched for
            [ "$(_ghc_stat "$_ghc_kc")" = "$_ghc_kst" ] || break
            printf '%s\t%s\t%s\t%s\n' "$_ghc_kc" "$_ghc_ks" "$_ghc_kv" ""
            return 0
        done < "$_ghc_rfile"
    fi

    _ghc_first=""        # first non-self candidate, the degraded fallback
    _ghc_skipped=""

    _ghc_oldifs=$IFS
    IFS=:
    for _ghc_p in $_ghc_path; do
        [ -n "$_ghc_p" ] || continue
        _ghc_cand="$_ghc_p/gh"
        [ -x "$_ghc_cand" ] || continue

        # exclude ourselves and any other nexus wrapper
        if [ -n "$_ghc_self" ]; then
            _ghc_cr=$(_ghc_rp "$_ghc_cand" 2>/dev/null || true)
            [ "$_ghc_cr" = "$_ghc_self" ] && continue
        fi
        _ghc_is_ghwrap "$_ghc_cand" && continue

        [ -n "$_ghc_first" ] || _ghc_first="$_ghc_cand"

        # `_ghc_meets` stashes what it read in `_ghc_last_ver`, so the version
        # is never probed twice for the same candidate.
        _ghc_meets "$_ghc_cand"
        case $? in
            0)  IFS=$_ghc_oldifs
                _ghc_cache_put "$_ghc_rfile" "$_ghc_path" "$_ghc_cand" ok "$_ghc_last_ver"
                printf '%s\t%s\t%s\t%s\n' "$_ghc_cand" ok "$_ghc_last_ver" "$_ghc_skipped"
                return 0 ;;
            1)  _ghc_skipped="${_ghc_skipped:+$_ghc_skipped,}${_ghc_cand}@${_ghc_last_ver}" ;;
            *)  # UNDETERMINABLE — and this candidate is TAKEN, not skipped.
                #
                # Skipping here was the first implementation and it was wrong in
                # the same way #755 is wrong. "I could not read a version" is
                # ABSENCE OF EVIDENCE; treating it as evidence of staleness lets
                # the resolver walk PAST a client and run a DIFFERENT binary
                # further down PATH — changing which program executes on the
                # strength of a silence. That is the defect class this file
                # exists to close, committed inside the fix for it.
                #
                # CI caught it: `test-gh-wrapper.sh`'s fake real-gh answers
                # every argv with a marker line and no version, so the resolver
                # stepped over it and reached the runner's own /usr/bin/gh —
                # six unit bands red. The host has no /usr/bin/gh, so it passed
                # locally, which is exactly why the boundary needed a machine
                # that disagrees with this one.
                #
                # So the floor DEMOTES ONLY ON POSITIVE PROOF (a parsed version
                # below it). Anything else runs where it always ran, flagged
                # `unverified` so no caller mistakes it for a vouched client.
                # The loud channel for this state is the spawn gate, which
                # measures the effective client once per spawn and warns.
                IFS=$_ghc_oldifs
                printf '%s\t%s\t%s\t%s\n' "$_ghc_cand" unverified "" "$_ghc_skipped"
                return 0 ;;
        esac
    done
    IFS=$_ghc_oldifs

    # `degraded` and `none` are deliberately NOT cached — see the header above.
    if [ -n "$_ghc_first" ]; then
        printf '%s\t%s\t%s\t%s\n' "$_ghc_first" degraded "$(_ghc_version "$_ghc_first")" "$_ghc_skipped"
        return 0
    fi
    printf '\t%s\t\t%s\n' none "$_ghc_skipped"
    return 0
}

# `_ghc_cache_put <file> <pathstr> <chosen> <status> <version>` — prepend this
# answer, keep the most recent `_ghc_cache_lines` distinct PATH keys, drop any
# previous line for the same key. Atomic via temp+rename, and every failure is
# swallowed: losing the cache costs latency, never correctness.
_ghc_cache_put() {
    [ -n "${1:-}" ] || return 0
    _ghc_cf="$1"; _ghc_cp="$2"; _ghc_cc="$3"; _ghc_cs="$4"; _ghc_cv="$5"
    _ghc_cst=$(_ghc_stat "$_ghc_cc")
    [ -n "$_ghc_cst" ] || return 0
    _ghc_cd=$(dirname "$_ghc_cf")
    mkdir -p "$_ghc_cd" 2>/dev/null || return 0
    _ghc_ct="$_ghc_cf.$$"
    {
        printf '%s\t%s\t%s\t%s\t%s\n' "$_ghc_cp" "$_ghc_cc" "$_ghc_cs" "$_ghc_cv" "$_ghc_cst"
        if [ -r "$_ghc_cf" ]; then
            _ghc_tab2=$(printf '\t')
            _ghc_n=1
            while IFS="$_ghc_tab2" read -r _ghc_op _ghc_rest; do
                [ "$_ghc_op" = "$_ghc_cp" ] && continue
                [ "$_ghc_n" -ge "$_ghc_cache_lines" ] && break
                printf '%s\t%s\n' "$_ghc_op" "$_ghc_rest"
                _ghc_n=$((_ghc_n + 1))
            done < "$_ghc_cf"
        fi
    } > "$_ghc_ct" 2>/dev/null && mv -f "$_ghc_ct" "$_ghc_cf" 2>/dev/null
    rm -f "$_ghc_ct" 2>/dev/null || true
    return 0
}
