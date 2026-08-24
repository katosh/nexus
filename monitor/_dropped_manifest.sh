#!/usr/bin/env bash
# Cold-boot dropped-worker manifest — the shared read side.
#
# When the operator boots the nexus WITHOUT `--continue`, the whole
# workspace comes up cold: `monitor/bootstrap-recover.sh` resurrects no
# worker agents at all (your-org/nexus-code#651). The work those workers
# were doing is not lost — it is on disk — but nothing would TELL the
# incoming orchestrator that it exists, so recovery writes a MANIFEST of
# exactly what it declined to resurrect and leaves it here for delivery.
#
# This file is the read side: the two surfaces that can put text in front
# of the orchestrator on its FIRST turn share these helpers so the
# manifest is delivered exactly once, wherever the orchestrator happens
# to come from:
#
#   - `monitor/watcher/spawn-fresh-orchestrator.sh` — inlines it into the
#     situation report pasted into the freshly spawned window. This is the
#     normal path: a cold boot has no orchestrator window, so recovery
#     spawns one and this report IS turn 1.
#   - `monitor/watcher/bootstrap.sh` — prints it on stdout at the start of
#     every orchestrator turn (the on-wake channel that already carries
#     missed diffs into context). The backstop for every other way an
#     orchestrator can arrive: the watcher's own absent-target respawn,
#     an operator-started session, a spawn whose paste failed.
#
# Delivery is once-only and tracked by a marker file, NOT by deleting the
# manifest: the manifest stays on disk as the audit record of what a cold
# boot dropped, and re-reading it is always possible. "Pending" means the
# manifest is NEWER than the delivery marker, so a later cold boot that
# rewrites the manifest automatically makes it pending again.
#
# Side-effect-free on source: function definitions only.

# Path of the manifest recovery writes. Arg: $1 state dir.
_dropped_manifest_path() { printf '%s/cold-boot-dropped-workers.md' "$1"; }

# Path of the delivery marker. Arg: $1 state dir.
_dropped_manifest_marker() { printf '%s/cold-boot-dropped-workers.delivered' "$1"; }

# mtime of a file in epoch seconds, or empty. Kept private so the two
# comparisons below cannot drift apart.
_dropped_manifest_mtime() {
    stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || true
}

# Is there an UNDELIVERED manifest? Exit 0 iff the manifest exists, is
# non-empty, and is strictly newer than the delivery marker (a missing
# marker means never delivered). Arg: $1 state dir.
#
# Strictly-newer rather than marker-absent is what makes a SECOND cold
# boot re-deliver: recovery rewrites the manifest, its mtime overtakes
# the old marker, and it goes pending again without anybody having to
# remember to clear the marker.
_dropped_manifest_pending() {
    local state_dir="$1"
    local manifest marker m_t k_t
    manifest=$(_dropped_manifest_path "$state_dir")
    [[ -s "$manifest" ]] || return 1
    marker=$(_dropped_manifest_marker "$state_dir")
    [[ -f "$marker" ]] || return 0
    m_t=$(_dropped_manifest_mtime "$manifest")
    k_t=$(_dropped_manifest_mtime "$marker")
    [[ "$m_t" =~ ^[0-9]+$ && "$k_t" =~ ^[0-9]+$ ]] || return 0
    (( m_t > k_t ))
}

# Record that the pending manifest has been put in front of the
# orchestrator. Best-effort: a state dir we cannot write means the
# manifest is delivered again next turn, which is noisy but never wrong.
# Arg: $1 state dir.
_dropped_manifest_mark_delivered() {
    local marker
    marker=$(_dropped_manifest_marker "$1")
    mkdir -p "$1" 2>/dev/null || true
    : > "$marker" 2>/dev/null || true
}

# Emit the pending manifest on stdout and mark it delivered. Prints
# nothing and returns 1 when nothing is pending, so callers can use it as
# both the test and the action. Arg: $1 state dir.
_dropped_manifest_deliver() {
    local state_dir="$1"
    _dropped_manifest_pending "$state_dir" || return 1
    cat -- "$(_dropped_manifest_path "$state_dir")" 2>/dev/null || return 1
    _dropped_manifest_mark_delivered "$state_dir"
    return 0
}
