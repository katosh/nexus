#!/usr/bin/env bash
# Nexus monitor — shared pane-state recording cache (your-org/nexus-code#562).
#
# WHY. The per-window sweep was O(N_windows × probes × forks), serial:
# `_idle_probe.sh` (idle/engagement), `_over_limit.sh`, the compose-time
# `render_idle_prelude` header, and `render_full_state_snapshot` each
# independently forked `monitor/pane-state.sh` once per window, and each
# fork spawns `tmux capture-pane` + a process-tree walk. At ~12 live
# windows that was dozens of serial subprocess spawns per cycle; under
# load the loop period blew to 255–495s and tripped the compose_emit
# 300s watchdog, delaying operator-comment surfacing (#562).
#
# WHAT. Record each window's pane-state emit line ONCE per sweep loop
# and let every assessment reuse that single recording:
#
#   - The AUTHORITATIVE recorder is the idle probe sweep
#     (`_v2_task_idle_section`, 30s cadence) — it runs with
#     MONITOR_PANE_CACHE_MODE=record, always forks a fresh probe per
#     window, and writes each result here. Idle/engagement detection —
#     the most staleness-sensitive consumer — therefore NEVER reads a
#     stale recording; it produces the recording.
#   - Every other assessment (over-limit scan, compose-time prelude,
#     full-state snapshot) runs in the default `read` mode: it serves
#     the recording when fresh (age ≤ TTL) and falls back to a direct
#     fork on miss/stale/corrupt — and that fallback WRITES the cache,
#     so one consumer's repair serves the next (bounded herd).
#
# The operator's "or as often as needed" nuance: a consumer that needs
# a guaranteed-fresh read bypasses the cache entirely. Action-taking
# probes (unstick fingerprinting, respawn pre-checks, the orchestrator
# idle-pane respawn guard, paste verification) do NOT go through this
# module at all — they keep their own direct tmux/pane-state calls.
#
# CONCURRENCY. Per-window entry files; writes are atomic
# (tmp.$BASHPID + rename); readers do a single read. Concurrent
# miss-filling writers race benignly (last-writer-wins with
# near-identical recordings — strictly no worse than the status quo of
# every consumer forking its own probe). No locks anywhere: this path
# must never be able to wedge the watcher's hot loop.
#
# FAIL-OPEN. Missing/stale/corrupt entry → direct fork. Unwritable
# cache dir → probes behave exactly as before this module existed.
# MONITOR_PANE_CACHE_TTL_SECONDS=0 disables the cache wholesale.
#
# ALIASING GUARD. tmux window indexes are reused after close/create, so
# a recording keyed by index could describe a WINDOW THAT NO LONGER
# EXISTS under that index. Callers that know the expected window name
# pass it to `_pane_cache_read`; a `name=` token mismatch is a miss.
#
# cc-version sensitivity: NONE. This module caches the INVOCATION of
# pane-state.sh; it never parses pane content itself. The
# cc-version-sensitive surface (pane-state.sh's TUI detectors) is
# untouched.

# ---- double-source guard ------------------------------------------------
if [[ -n "${_NEXUS_PANE_CACHE_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_PANE_CACHE_LOADED=1

# Acceptance TTL for read-mode consumers. Default 90s = 3× the
# authoritative recorder cadence (idle_section @30s): tolerates one
# slow/skipped recorder fire before consumers fall back to direct
# forks, while bounding worst-case staleness of any served recording.
# 0 disables the cache (every consumer forks, nothing is written).
: "${MONITOR_PANE_CACHE_TTL_SECONDS:=90}"

# Per-invocation mode, consulted by the probe chokepoints:
#   read    (default) serve fresh recordings; fork + write-back on miss
#   record  always fork fresh, write the recording (the sweep recorder)
#   off     always fork, never read or write (kill switch / tests)
: "${MONITOR_PANE_CACHE_MODE:=read}"

_pane_cache_enabled() {
    [[ "${MONITOR_PANE_CACHE_TTL_SECONDS}" =~ ^[0-9]+$ ]] || return 1
    (( MONITOR_PANE_CACHE_TTL_SECONDS > 0 ))
}

_pane_cache_dir() {
    printf '%s\n' "${MONITOR_PANE_CACHE_DIR:-${STATE_DIR:-/tmp}/pane-cache}"
}

# Filesystem-safe key for a probe target (window index, session:window,
# or name-fallback in test stubs).
_pane_cache_key() {
    local target="$1"
    printf '%s\n' "${target//[^A-Za-z0-9._-]/_}"
}

# _pane_cache_read <target> [expected_name]
#
# Print the cached pane-state emit line for <target> and return 0 IFF
# the entry exists, is fresh (age ≤ TTL), parses as a pane-state line
# (`state=` token present), and — when <expected_name> is given —
# carries a matching `name=` token. Any other condition returns 1
# (caller falls back to a direct fork).
_pane_cache_read() {
    local target="$1" expected_name="${2:-}"
    _pane_cache_enabled || return 1
    [[ "${MONITOR_PANE_CACHE_MODE:-read}" == "read" ]] || return 1
    local f
    f="$(_pane_cache_dir)/$(_pane_cache_key "$target").line"
    [[ -f "$f" ]] || return 1
    local mtime now age
    mtime=$(stat -c %Y "$f" 2>/dev/null) || return 1
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)
    age=$(( now - mtime ))
    # A negative age (clock skew / touched-in-the-future file) is as
    # untrustworthy as a stale one — treat as miss.
    (( age >= 0 && age <= MONITOR_PANE_CACHE_TTL_SECONDS )) || return 1
    local line
    line=$(head -n1 "$f" 2>/dev/null) || return 1
    [[ "$line" == *state=* ]] || return 1
    if [[ -n "$expected_name" ]]; then
        # Window-index reuse guard: the recording must describe the
        # window the caller thinks it describes. Only enforced when the
        # line actually carries a name token (pane-state.sh always
        # emits one; a test stub's minimal line passes through).
        if [[ "$line" == *name=* ]]; then
            local rec_name
            rec_name=$(printf '%s' "$line" | sed -n 's/.*name=\([^ ]*\).*/\1/p')
            [[ "$rec_name" == "$expected_name" ]] || return 1
        fi
    fi
    printf '%s\n' "$line"
    return 0
}

# _pane_cache_write <target> <line>
#
# Record <line> as the current recording for <target>. Atomic
# (tmp.$BASHPID + rename); best-effort — a failed write leaves the
# system exactly as it was before this module existed. Never called
# with an empty line (callers guard), but tolerate one defensively.
_pane_cache_write() {
    local target="$1" line="$2"
    _pane_cache_enabled || return 0
    [[ "${MONITOR_PANE_CACHE_MODE:-read}" == "off" ]] && return 0
    [[ -n "$line" ]] || return 0
    local dir f
    dir=$(_pane_cache_dir)
    mkdir -p "$dir" 2>/dev/null || return 0
    f="$dir/$(_pane_cache_key "$target").line"
    # `2>/dev/null` BEFORE the `>` redirect: bash applies redirections
    # left-to-right, so the other order leaks a shell error line when
    # the dir is unwritable (the fail-open case must stay silent).
    printf '%s\n' "$line" 2>/dev/null > "$f.tmp.$BASHPID" \
        && mv -f "$f.tmp.$BASHPID" "$f" 2>/dev/null \
        || rm -f "$f.tmp.$BASHPID" 2>/dev/null || true
    return 0
}

# Drop entries older than 10× TTL plus any orphaned tmp files. Cheap
# (one find over a small dir); called opportunistically by the
# recorder so the dir doesn't accumulate keys of long-gone windows.
_pane_cache_gc() {
    _pane_cache_enabled || return 0
    local dir keep_min
    dir=$(_pane_cache_dir)
    [[ -d "$dir" ]] || return 0
    keep_min=$(( (MONITOR_PANE_CACHE_TTL_SECONDS * 10 + 59) / 60 ))
    (( keep_min < 1 )) && keep_min=1
    find "$dir" -maxdepth 1 -type f \
        \( -name '*.line' -o -name '*.line.tmp.*' \) \
        -mmin +"$keep_min" -delete 2>/dev/null || true
    return 0
}

# Test-only: wipe the cache dir.
_pane_cache_reset_for_tests() {
    local dir
    dir=$(_pane_cache_dir)
    [[ -n "$dir" && "$dir" != "/" ]] || return 0
    rm -f "$dir"/*.line "$dir"/*.line.tmp.* 2>/dev/null || true
    return 0
}
