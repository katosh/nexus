#!/usr/bin/env bash
# monitor/ensure-workdir-trusted.sh — pre-seed Claude Code's workspace-trust
# entry for a worker's workdir, so an interactive spawn never boots into the
# "Do you trust this folder?" dialog.
#
# WHY THIS EXISTS (Claude Code 2.1.232):
#
#   "Fixed nested git repositories inheriting trust from a parent directory;
#    each repository now requires its own trust confirmation"
#
# The nexus spawns workers with cwd = work/<project>. Those are SEPARATE git
# repos nested inside the nexus git repo, and the operator's ~/.claude.json
# typically trusts only the nexus root — every work/<project> was trusted by
# INHERITANCE. From 2.1.232 that inheritance is gone, so each such spawn
# stops on a trust dialog and never reaches an idle REPL.
#
# Two properties make that failure especially bad, and are the reason this
# runs at spawn time rather than being left to an operator:
#
#   1. No flag or env var bypasses it. `--dangerously-skip-permissions` and
#      `skipDangerousModePermissionPrompt: true` are BOTH already in the
#      production spawn path and neither suppresses the dialog; the dialog is
#      skipped only in non-interactive mode (-p / non-TTY), and workers are
#      interactive TUI panes. `projects.<dir>.hasTrustDialogAccepted` in
#      .claude.json is the only DOCUMENTED mechanism. Measured on 2.1.261
#      (your-org/nexus-code#1334): the binary also honours an UNDOCUMENTED
#      env `CLAUDE_CODE_SANDBOXED=1` that returns "trusted" before the key
#      is read. spawn-worker.sh's launchers now SET it — measured, with
#      the real worker configuration, to change nothing observable but the
#      trust gate — and it is the PRIMARY fix for #1334; this seed stays
#      as the declared, documented mechanism and the recovery loop as the
#      fallback. cc-version-sensitive (an env read at 3 sites in a binary
#      re-pinned weekly): guarded by the real-binary canary
#      monitor/watcher/test-integration/test-realmodel-trust-sandboxed-env.sh.
#
#      AND THE SEED IS NECESSARY, NOT SUFFICIENT. One of five clones seeded
#      by this script in one session still booted into the dialog with the
#      key present afterwards (#1334). spawn-worker.sh therefore VERIFIES
#      after sending the launcher (`_sw_trust_verify`) and, on
#      `state=blocked overlay=workspace-trust`, re-seeds through this
#      script, reads the key back, and re-creates the window — bounded,
#      exit 21 when exhausted. The "claude rewrites the file wholesale from
#      stale memory" hypothesis was measured FALSE on all three of the
#      binary's write paths (accept / exit / startup: external seeds
#      survived, inode changed each write = temp+rename); the residual is
#      a narrow read-modify-write interleave claude takes no lock against.
#   2. CORRECTED (your-org/nexus-code#1015 finding 4). This used to read
#      "pane-state.sh classifies the trust-dialog frame as `state=empty
#      active=0`, NOT `blocked` — so the failure is silent to the whole
#      control surface". That was true when #888 was written and is now
#      FALSE: #896 added a `workspace-trust` overlay arm
#      (monitor/pane-state.sh, `printf 'workspace-trust'`), and a worker
#      hung on the dialog measures as
#          state=blocked active=0 overlay=workspace-trust
#      so it DOES present to the watcher as a stuck pane.
#
#      Corrected rather than deleted, because the sentence is load-bearing
#      for how urgent this seeder is, and the direction of the error is the
#      dangerous one: it overstates the hazard, so a future author reading
#      it would keep a mitigation for a reason that no longer holds and
#      never learn which of the two reasons was doing the work. The seeder
#      is still worth having — it prevents the hang rather than detecting
#      it — but it is no longer the only thing standing between a hung
#      worker and an unobserved board.
#
# This widens no trust boundary. The nexus already launches these workers, in
# these exact directories, with --dangerously-skip-permissions; the operator
# granted that by spawning. Seeding makes an already-implicit grant explicit.
#
# Usage:
#   monitor/ensure-workdir-trusted.sh <workdir>        # seed one directory
#   monitor/ensure-workdir-trusted.sh --backfill <dir> [--depth N]
#                                      # seed <dir> and the directories under
#                                      # <dir>/work. DEFAULT depth 2 =
#                                      # <dir>/work/<x> only; the run always
#                                      # reports how many deeper directories
#                                      # it did not visit (#1015 finding 2).
#
# Exit: 0 seeded or already trusted (idempotent); 1 usage; 2 cannot proceed
# (no jq, unwritable/corrupt config). Callers treat non-zero as a spawn
# blocker: booting anyway just produces the silent hang described above.
set -uo pipefail

usage() {
    echo "usage: monitor/ensure-workdir-trusted.sh <workdir>" >&2
    echo "       monitor/ensure-workdir-trusted.sh --backfill <nexus-root> [--depth N]" >&2
    echo "" >&2
    echo "  --depth N  how far below <nexus-root>/work to descend, in the" >&2
    echo "             vocabulary of your-org/nexus-code#1015: 2 = work/<x>" >&2
    echo "             (the DEFAULT, and what this tool has always done)," >&2
    echo "             3 = work/<x>/<y>, and so on. Whatever the depth, the" >&2
    echo "             run reports how many deeper directories it did NOT" >&2
    echo "             visit; those are seeded on first spawn regardless." >&2
    exit 1
}

# The config file claude actually reads. CLAUDE_CONFIG_DIR wins when set
# (that is how the cc-harness isolates its own runs), else $HOME.
_ewt_config_file() {
    printf '%s/.claude.json' "${CLAUDE_CONFIG_DIR:-$HOME}"
}

# Seed one absolute path. Fast-path returns WITHOUT writing when the entry is
# already true — after the first spawn per workdir this script never touches
# the file again, which matters because claude itself writes .claude.json
# concurrently and every avoided write is an avoided clobber window.
ensure_trusted() {
    local dir="$1" cfg lock tmp abs
    cfg=$(_ewt_config_file)

    abs=$(CDPATH= cd "$dir" 2>/dev/null && pwd -P) || {
        echo "ensure-workdir-trusted: not a directory: $dir" >&2; return 2; }

    command -v jq >/dev/null 2>&1 || {
        echo "ensure-workdir-trusted: jq not found; cannot seed workspace trust for $abs" >&2
        return 2; }

    # Fast path: already trusted → no lock, no write.
    if [ -f "$cfg" ] \
        && [ "$(jq -r --arg d "$abs" \
              '.projects[$d].hasTrustDialogAccepted // false' "$cfg" 2>/dev/null)" = "true" ]; then
        return 0
    fi

    lock="${cfg}.nexus-trust.lock"
    tmp="${cfg}.nexus-trust.$$"

    # Serialise against OTHER nexus spawns (claude's own writer does not take
    # this lock, hence the re-read inside it and the atomic rename below —
    # the window stays as small as a read-modify-rename can be).
    { exec 9>"$lock"; } 2>/dev/null || {
        echo "ensure-workdir-trusted: cannot create lock $lock" >&2; return 2; }
    flock 9 2>/dev/null || true

    # Re-read INSIDE the lock: another spawn may have seeded it (or claude may
    # have rewritten the file) between the fast path and here.
    if [ -f "$cfg" ]; then
        if ! jq -e . "$cfg" >/dev/null 2>&1; then
            echo "ensure-workdir-trusted: $cfg is not valid JSON — refusing to rewrite it" >&2
            { exec 9>&-; } 2>/dev/null; return 2
        fi
        if [ "$(jq -r --arg d "$abs" \
              '.projects[$d].hasTrustDialogAccepted // false' "$cfg" 2>/dev/null)" = "true" ]; then
            { exec 9>&-; } 2>/dev/null; return 0
        fi
    else
        printf '{}\n' > "$cfg" 2>/dev/null || {
            echo "ensure-workdir-trusted: cannot create $cfg" >&2
            { exec 9>&-; } 2>/dev/null; return 2; }
    fi

    # Merge, never replace: `*` deep-merges so every other key claude keeps in
    # this file (auth, history, per-project allowedTools) survives untouched,
    # and an existing project entry keeps its other fields.
    if ! jq --arg d "$abs" \
            '. * {projects: {($d): {hasTrustDialogAccepted: true}}}' \
            "$cfg" > "$tmp" 2>/dev/null; then
        echo "ensure-workdir-trusted: failed to compute updated config for $abs" >&2
        rm -f "$tmp" 2>/dev/null; { exec 9>&-; } 2>/dev/null; return 2
    fi
    # Never install an empty/garbage result over a live config.
    if ! jq -e . "$tmp" >/dev/null 2>&1; then
        echo "ensure-workdir-trusted: refusing to install malformed config for $abs" >&2
        rm -f "$tmp" 2>/dev/null; { exec 9>&-; } 2>/dev/null; return 2
    fi
    if ! mv -f "$tmp" "$cfg" 2>/dev/null; then
        echo "ensure-workdir-trusted: failed to install $cfg" >&2
        rm -f "$tmp" 2>/dev/null; { exec 9>&-; } 2>/dev/null; return 2
    fi

    { exec 9>&-; } 2>/dev/null
    echo "ensure-workdir-trusted: seeded workspace trust for $abs"
    return 0
}

# --backfill: seed the root plus the directories under <root>/work, so an
# operator adopting this fix does not wait for each project's first spawn to
# discover the dialog one at a time.
#
# THE SCOPE IS MEASURED AND REPORTED, NOT ASSERTED (your-org/nexus-code#1015
# finding 2). This used to be `for d in "$root"/work/*/`, which is TWO things
# at once and said neither: it reached exactly ONE level, and a bare glob does
# not match dotfiles. On the operator's tree that was 662 of 919 repos — the
# missing 257 are not exotic, they are the conventions this workspace uses
# constantly (`<clone>/assets/`, `<project>/.worktrees/<branch>/`, and
# sibling-clone families). A tool that seeds a slice while its name and its
# --help say it seeds the population is this bundle's own defect class: a
# verdict claiming more than was measured.
#
# The DEFAULT IS UNCHANGED (--depth 2, i.e. `work/<x>`) on purpose. Seeding is
# a lock + jq read-modify-rename against the operator's LIVE .claude.json,
# which claude itself writes concurrently; silently multiplying that by four
# because a depth argument was added would be a behavioural change nobody
# asked for. What changes is that the tool now COUNTS what it did not visit
# and prints it, so the residual is a number in the output rather than a
# sentence in a comment — and `--depth N` is there when an operator wants it.
#
# Direction of the residual, stated because a scope claim needs one: at the
# default this UNDER-seeds. Under-seeding is the safe direction — an unseeded
# workdir is seeded on its first spawn by spawn-worker.sh, which calls
# ensure_trusted on $WORKDIR at ANY depth. Backfill is a convenience, never
# the enforcement.
backfill() {
    local root="$1" depth="${2:-2}" rc=0 d seeded=0 failed=0 visited=0 deeper=0
    ensure_trusted "$root" || rc=$?

    if [ -d "$root/work" ]; then
        # `find`, not a glob: the glob is depth-blind AND dotfile-blind, and
        # -mindepth/-maxdepth make the level an argument rather than a
        # property of how many `*/` were typed. -print0/read -d keeps paths
        # with spaces intact.
        while IFS= read -r -d "" d; do
            visited=$((visited + 1))
            if ensure_trusted "$d"; then
                seeded=$((seeded + 1))
            else
                rc=$?
                failed=$((failed + 1))
                # Name every failing member. Before #1015 finding 1 this line
                # could not be seen: the first `exec 9>… 2>/dev/null` silenced
                # the shell's stderr for the rest of the process, so in a
                # backfill every per-member diagnostic after the first write
                # went to /dev/null.
                echo "ensure-workdir-trusted: backfill: FAILED to seed $d (rc=$rc)" >&2
            fi
        done < <(find "$root/work" -mindepth 1 -maxdepth "$((depth - 1))" -type d -print0 2>/dev/null)

        # What was NOT visited, counted rather than described. A zero here is
        # a measurement; the absence of this line would be an assumption.
        deeper=$(find "$root/work" -mindepth "$depth" -type d -print 2>/dev/null | wc -l)
    fi

    echo "ensure-workdir-trusted: backfill scope: depth=$depth visited=$visited seeded=$seeded failed=$failed not-visited-deeper=$deeper" >&2
    if [ "$deeper" -gt 0 ]; then
        echo "ensure-workdir-trusted: $deeper director(y|ies) below depth $depth were NOT visited. They are seeded on first spawn by spawn-worker.sh; re-run with --depth N to seed them now." >&2
    fi
    return $rc
}

case "${1:-}" in
    ""|-h|--help) usage ;;
    --backfill)
        [ $# -ge 2 ] || usage
        # --depth N is OPTIONAL and validated by SHAPE, never by emptiness:
        # a non-numeric value would reach `$((depth - 1))` and be fatal under
        # arithmetic evaluation, which is a refusal nobody can read.
        _ewt_depth=2
        if [ $# -ge 4 ] && [ "$3" = "--depth" ]; then
            case "$4" in
                ''|*[!0-9]*)
                    echo "ensure-workdir-trusted: --depth expects a positive integer, got '$4'" >&2
                    exit 1 ;;
            esac
            [ "$4" -ge 2 ] || {
                echo "ensure-workdir-trusted: --depth must be >= 2 (2 = <root>/work/<x>, the default)" >&2
                exit 1; }
            _ewt_depth="$4"
        elif [ $# -gt 2 ]; then
            usage
        fi
        backfill "$2" "$_ewt_depth"
        ;;
    *)
        [ $# -eq 1 ] || usage
        ensure_trusted "$1"
        ;;
esac
