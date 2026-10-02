#!/usr/bin/env bash
# monitor/evidence-freeze.sh — freeze an artefact into durable evidence
# storage so that a later overwrite CANNOT pass the integrity check.
#
# WHY. A freeze is the copy that proves, afterwards, that nothing was
# lost. The hand-rolled form every worker prompt has carried so far is:
#
#     cp -p <artefact> "$EV/<name>"
#     cd "$EV" && md5sum *.ipynb > MANIFEST.md5 && md5sum -c MANIFEST.md5
#
# Run twice, that destroys the baseline AND refreshes the checksum that
# would have caught it, so `md5sum -c` reports OK on the substituted
# bytes. `cp -p` compounds it: the copy keeps the SOURCE mtime, so the
# replaced file does not even look freshly written. That sequence
# destroyed an 11,648,117-byte baseline (`fb2c326b…`) on 2026-09-09; it
# is unrecoverable. The first three properties this script enforces are
# each the inverse of one of those mistakes:
#
#   1. REFUSE TO CLOBBER. An existing target is an error, never an
#      overwrite. The first freeze under a name wins.
#   2. READ-ONLY COPIES (mode 0440). A later `cp` over a frozen file
#      fails with EACCES instead of succeeding quietly.
#   3. APPEND-ONLY MANIFEST. `MANIFEST.md5` is left mode 0440, so a
#      wholesale `md5sum … > MANIFEST.md5` fails with EACCES. This
#      script appends (`>>`) under a brief chmod, and refuses to append
#      a name the manifest already records.
#
# A fourth property answers a mistake the incident did not make, but
# that the first three cannot see:
#
#   4. OUT-OF-BAND RECORD. Every freeze also appends one line to a
#      `freeze-log.jsonl` OUTSIDE the evidence directory, and
#      `--verify` cross-checks the directory against it. Properties 1
#      to 3 read only the evidence directory, so a directory that was
#      emptied and rebuilt is self-consistent and passes all three.
#      Property 4 is the only one that can see that.
#
# It also copies WITHOUT `-p`, so the frozen file's mtime is the time
# the freeze happened — the evidence a reader needs.
#
# WHAT MODE 0440 DOES NOT PREVENT. Mode 0440 stops a WRITE to a frozen
# file. It does not stop an UNLINK: the evidence directory itself is
# mode 0770, so the owning uid can `rm` a freeze and its manifest,
# recreate both, and every check that reads only this directory then
# reports clean on the new bytes.
#
# Two options were on the table to close that gap. The operator chose B
# on 2026-09-09, and B is what this script now implements.
#
#   A. HOLD THE DIRECTORY READ-ONLY between freezes — REJECTED.
#      Removing a file needs write permission on the DIRECTORY, never
#      on the file, so this is the only local file mode that stops the
#      unlink at the time it is attempted. It was rejected for three
#      reasons. It blocks every other write into the directory, which
#      includes sub-directories and the notes a reader legitimately
#      adds. The owning uid can `chmod` the directory back in one
#      command, so it stops an accident and not a decision. And it
#      leaves no trace: after that `chmod` the directory looks exactly
#      like one that was never protected, so nothing afterwards can
#      tell the two apart.
#   B. RECORD EACH FREEZE OUT OF BAND — IMPLEMENTED. Every freeze
#      appends one line to a `freeze-log.jsonl` that lives in the state
#      directory, OUTSIDE the evidence directory. `--verify` then
#      cross-checks the directory against those lines. Directory
#      permissions do not change at all. See "THE OUT-OF-BAND FREEZE
#      LOG" below for the file, the schema and the exact rule.
#
# WHAT B DELIVERS, AND WHAT IT DOES NOT. B does NOT make tampering
# impossible, and no wording in this script may suggest that it does.
# B makes tampering need a CONSISTENT EDIT IN TWO PLACES: the evidence
# directory, and the shared freeze log. The remove-and-recreate
# sequence above now fails `--verify` with exit 8, because the
# recreated bytes do not match the hash recorded out of band. The same
# uid can still edit the freeze log to agree with the new bytes, and
# `--verify` reports clean again. `test-evidence-freeze.sh` case 21
# runs that two-place edit and pins it as PASSING, so the suite is
# never read as proof of impossibility.
#
# B also does not stop a `rm`. Nothing in this script does. B changes
# what a `rm` costs. The removal is DETECTED afterwards instead of
# PREVENTED at the time, and the record that the freeze existed
# survives the removal of the whole evidence directory.
#
# Usage:
#   evidence-freeze.sh <source> --task <slug> [--as <name>]
#   evidence-freeze.sh <source> --dir <evidence-dir> [--as <name>]
#   evidence-freeze.sh --verify (--task <slug> | --dir <evidence-dir>)
#
#   --task <slug>   evidence dir is $STATE_DIR/evidence/<slug> (created
#                   if missing). The usual form; <slug> is the task or
#                   window name.
#   --dir <path>    an explicit evidence directory (created if missing).
#   --as <name>     frozen name (default: the source's basename). Give
#                   a name that marks the pass, e.g. `nb.PRE_FIXPASS.ipynb`.
#   --verify        check every manifest entry, plus the mode-0440, the
#                   manifest-coverage and the freeze-log invariants.
#                   Writes nothing.
#
# Exit codes:
#   0  frozen (or verified clean)
#   2  bad usage / unreadable source
#   3  target already exists — REFUSED (nothing was written)
#   4  MANIFEST.md5 already records that name, or cannot be appended to
#   5  --verify found a mismatch, a missing file, or a broken invariant
#   6  --verify found a regular file the manifest does not record
#   7  a mode this script promises could not be set (see MODE CHECKS)
#   8  the out-of-band freeze log and the directory disagree, or a
#      freeze could not be recorded in it (see THE OUT-OF-BAND FREEZE
#      LOG)
# END-USAGE
#
# `usage()` prints the block between `# Usage:` and `# END-USAGE`. The
# end marker is explicit because the previous form ended the range on
# the last exit code, which meant that adding exit 8 truncated the help
# text. A marker cannot be broken by a later entry.
#
# EXIT 6, AND WHAT IT DOES AND DOES NOT LOOK AT. `--verify` checks
# REGULAR FILES AT THE TOP LEVEL of the evidence directory only. It
# does not descend into sub-directories, and it exempts no name. That
# scope is the manifest's own scope: `md5sum <name>` records a bare
# name in one directory, so a name in a sub-directory could not be
# recorded even in principle. The rule is deliberately name-blind. A
# README exemption would be a hole any file could enter through, and
# an unrecorded note is exactly the thing a reader should be told
# about. Exit 5 wins if both fire, because a broken invariant is the
# graver finding.
#
# "RECORDED" IS NOT THE SAME AS "RECORDED UNDER A BARE NAME", and the
# difference is not hypothetical. Manifests in this repo were written by
# hand before this script existed, and they use five name forms:
#
#     nb.txt                                      bare
#     ./nb.txt                                    from `md5sum ./*.txt`
#     *nb.txt                                     from `md5sum -b`
#     monitor/.state/evidence/<task>/nb.txt       repo-root-relative
#     ./harness/nb.txt                            sub-directory path
#
# The first three are the same bare name and are read as such. The last
# two name this very file by a longer path. A row like that ACCOUNTS FOR
# the bytes, so `--verify` must not call the file unrecorded. It once
# did: on the live store its only three findings were all files recorded
# by a repo-root-relative path, and the remedy printed with them — freeze
# the file — is refused with exit 3, because the file is already there.
# A message that is false and a remedy the tool itself rejects.
#
# So `--verify` now asks a second question before it calls anything
# unrecorded. If a manifest row's BASENAME matches the file AND the
# recorded hash matches the bytes on disk, the file is accounted for:
# a NOTE is printed and exit 6 does not fire. Both conditions, never
# either. If the basename matches and the hash does NOT, the bytes
# changed under a recorded name — that is exit 5, and it is a case
# `md5sum -c` cannot reach, because a path-qualified row does not
# resolve from inside the directory. That same non-resolution is why
# such a directory also reports a checksum mismatch.
#
# WHAT THIS DELIBERATELY DOES NOT DECIDE. `_manifest_records`, which
# guards the FREEZE side, is unchanged: it still keys on the three bare
# forms only. So a path-qualified row does not block a name from being
# frozen. Whether it should is a genuine design question with a
# defensible answer either way, and it is the operator's to settle.
#
# The remedy for a genuinely unrecorded file is to freeze it, which
# records it. That remedy is correct only for the case above, where no
# manifest row names the file at all.
#
# THE OUT-OF-BAND FREEZE LOG. This is option B, and this section is the
# whole of it.
#
# WHERE. `$STATE_DIR/freeze-log.jsonl`, overridable with
# `NEXUS_FREEZE_LOG`. It is NOT in the evidence directory, on purpose:
# removing an evidence directory must not remove the evidence that the
# directory existed. It is also not under any evidence directory's
# parent, so `--verify` never reads a record the same `rm -rf` could
# have taken.
#
# WHY A DEDICATED FILE AND NOT `action-log.jsonl`. `action-log.jsonl`
# was the other candidate, and it was rejected on durability. The
# watcher rotates it at `monitor.state_log_max_bytes` (10 MiB) and then
# DELETES the rotated archive after `DIFF_RETENTION_DAYS` (default 7).
# That lifecycle is correct for a telemetry trace and wrong for a
# record of record: a freeze record has to outlive the artefact it
# describes, which is the whole point of freezing. Measured on the live
# store on 2026-09-09: 4,987 rows, 1,417,332 bytes, first row
# 2026-06-16 — about 16 KiB a day, so the cap arrives in roughly two
# years and the archive is gone a week later. Two years is not
# "durable". A second reason: `action-log.jsonl` takes rows from every
# agent through `ng log-action`, with free-form `--extra k=v` pairs, so
# it has many writers and no fixed schema. `freeze-log.jsonl` has one
# writer and one schema, it is never rotated, and it grows one line per
# freeze.
#
# SCHEMA. One JSON object per line, fields in this order:
#
#   v       schema version, integer, currently 1. A later schema change
#           must be DETECTED, not mis-parsed, because this file gates a
#           check.
#   ts      ISO-8601 local time with offset. When the freeze happened.
#   event   always `freeze` today. Present so the file can later carry
#           a second row type without a reader having to guess.
#   dir     the evidence directory, absolute and symlink-resolved. The
#           join key: `--verify` reads the rows whose `dir` equals the
#           directory it was given, resolved the same way.
#   name    the frozen basename, as it appears in `MANIFEST.md5`.
#   md5     the frozen bytes. The value the cross-check compares.
#   bytes   the frozen size. Not a second integrity check — it is a
#           reader aid. The incident is remembered by its size
#           (11,648,117 bytes) and a row that carries the size can be
#           matched against a memory of the artefact, not just against
#           a hash nobody memorised.
#   src     the source path the bytes were copied from. Provenance:
#           `md5` says WHAT was frozen, `src` says where it came from.
#   window  `$NEXUS_WORKER_WINDOW`, or empty. The action log keys its
#           whole spawn and wrap-up trace by window, so a freeze row
#           that carries the window joins to that trace.
#
# THE CROSS-CHECK, EXACTLY. For the directory under `--verify`:
#
#   * every logged (dir, name) whose file is ABSENT is exit 8;
#   * every logged (dir, name) whose bytes do not match the logged
#     `md5` is exit 8;
#   * two rows for the same (dir, name) is exit 8. This script never
#     writes a second row for a name — property 1 refuses the target
#     and the manifest refuses the name — so a duplicate means the
#     directory was emptied and re-frozen, which is the bypass run
#     through this script instead of around it;
#   * a top-level file with NO row is NOT an error. See the next
#     paragraph.
#
# A FILE WITH NO ROW IS REPORTED, NEVER SILENTLY PASSED. Hard-failing
# on a directory the log does not cover was rejected: on the live store
# on 2026-09-09 there were ten evidence directories and the log covers
# NONE of them, because the log did not exist until this change. Two of
# the ten have no `MANIFEST.md5` either. A check that fails on all ten
# is a check an operator turns off. Silently passing was rejected too,
# because that is the hole this change exists to close. So `--verify`
# passes an uncovered file and SAYS SO: it always prints a coverage
# line, and the clean verdict itself carries the count, e.g.
#
#     evidence-freeze: <dir> verified clean (freeze-log covers 2 of 5)
#
# A reader can never mistake an uncovered directory for a cross-checked
# one, because the clean line is not the same line in the two cases.
# Coverage is per FILE, not per directory, so a directory that predates
# this change starts being covered the moment the next freeze lands in
# it, one file at a time.
#
# WHAT THE CROSS-CHECK CANNOT SEE. Deleting a row makes its file
# uncovered, and an uncovered file passes. That is the same two-place
# edit named at the top of this header, done in the cheaper direction.
# Moving an evidence directory also drops its coverage to zero, because
# `dir` is an absolute path; the rows survive, but they no longer join.
# Both are stated here so that no reader infers a guarantee from a
# clean verdict.
#
# CONCURRENCY. Several agents freeze at once, and the state directory
# is on NFS, where an `O_APPEND` write is not guaranteed atomic even
# below `PIPE_BUF`. Each append therefore takes an exclusive `flock` on
# `$FREEZE_LOG.lock` — a separate file, so the lock never needs the log
# itself to be writable — and holds it across the whole `chmod u+w` →
# `>>` → `chmod 0440` sequence. That also serialises the two `chmod`s,
# which would otherwise race each other. If the lock cannot be taken,
# for any reason, the append still happens and a WARNING says the
# append was unserialised. A silent unlocked append would be the same
# failure this script exists to prevent: a success message standing in
# for a check nobody ran.
#
# The log is held mode 0440 between appends, exactly like
# `MANIFEST.md5`, so a stray `>` redirect fails with EACCES. `--verify`
# reports a writable log as a broken invariant (exit 5). A process
# killed between the two `chmod`s leaves the log writable, and that is
# the report a reader should get.
#
# MODE CHECKS. A `chmod` can fail. This script therefore reads the mode
# back with `stat` after setting it, and exits 7 rather than printing
# `mode 0440` over an unverified property. That failure is the exact
# shape of the incident this guard exists to prevent: a success message
# standing in for a check nobody ran.
#
# Env seams (tests): NEXUS_STATE_DIR / NEXUS_ROOT resolve the state dir,
# exactly as pane-state.sh and retire-preflight.sh resolve it.
# NEXUS_FREEZE_LOG overrides the freeze-log path on its own, so a test
# can keep the log inside its own `mktemp -d` without moving the state
# dir. `test-evidence-freeze.sh` sets it once, for the whole suite.

set -uo pipefail

usage() {
    sed -n '/^# Usage:/,/^# END-USAGE/p' "${BASH_SOURCE[0]}" \
        | sed '/^# END-USAGE/d; s/^# \{0,1\}//'
    exit 2
}

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || self_dir="."

# ---- resolve STATE_DIR (mirrors pane-state.sh / retire-preflight.sh) ------
if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    STATE_DIR="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    STATE_DIR="$NEXUS_ROOT/monitor/.state"
else
    STATE_DIR="$self_dir/.state"
fi

MANIFEST_NAME="MANIFEST.md5"

# The out-of-band record. Outside every evidence directory, on purpose
# — see "THE OUT-OF-BAND FREEZE LOG" in the header.
FREEZE_LOG="${NEXUS_FREEZE_LOG:-$STATE_DIR/freeze-log.jsonl}"
FREEZE_LOG_SCHEMA=1

# Does the manifest already record this bare name? Both the freeze path
# and --verify ask this, so it is defined once, before either runs.
#
# Match the name field EXACTLY — a substring test would refuse
# `nb.ipynb.bak` because `nb.ipynb` is already recorded. Three BARE name
# forms reach us, and all three mean the same file in this directory:
#   `<hash>  nb.txt`    GNU md5sum, text mode
#   `<hash> *nb.txt`    GNU md5sum, binary mode
#   `<hash>  ./nb.txt`  a manifest built by `md5sum ./*.txt`
#
# Those three are all this function reads. It does NOT read the two
# PATH-QUALIFIED forms the live store also holds. An earlier version of
# this comment said "a manifest this script did not write is still read
# correctly"; two live manifests falsify that, and the claim is
# withdrawn. Only `--verify` handles the longer forms, through
# `_manifest_hash_for_basename` below — see the header.
_manifest_records() {
    local m="$1" n="$2"
    [[ -f "$m" ]] || return 1
    # The name arrives through the ENVIRONMENT, not through `awk -v`.
    # `awk -v x='a\db'` runs the value through awk's own escape
    # processing, so a backslash in a file name silently becomes
    # something else and the comparison never matches. `ENVIRON` is
    # passed through byte for byte.
    EF_WANT="$n" awk '{ line = $0
                        want = ENVIRON["EF_WANT"]
                        sub(/^[^ ]+[ ]+/, "", line)
                        sub(/^\*/, "", line)
                        sub(/^\.\//, "", line)
                        if (line == want) found = 1 }
                      END { exit found ? 0 : 1 }' "$m"
}

# Read a mode back after setting it. A chmod can fail, and this script
# must never print a property it did not check.
_mode_is() {
    [[ "$(stat -c '%a' -- "$1" 2>/dev/null)" == "$2" ]]
}

# Print the recorded hash of the first manifest row whose name, reduced
# to a bare basename, equals $2. Empty when no row matches.
#
# This is DELIBERATELY looser than `_manifest_records`, and only
# `--verify` uses it. Real manifests in this repo record
# `monitor/.state/evidence/<task>/<name>` and `./harness/<name>`, not
# just bare names. Such a row names this very file, so treating the file
# as unrecorded is a false statement about the directory. See "EXIT 6"
# in the header for the exact rule and what it does NOT decide.
_manifest_hash_for_basename() {
    local m="$1" n="$2"
    [[ -f "$m" ]] || return 1
    # ENVIRON, not `awk -v` — see `_manifest_records` above.
    EF_WANT="$n" awk '{ hash = $0; sub(/[ ].*$/, "", hash)
                        want = ENVIRON["EF_WANT"]
                        line = $0
                        sub(/^[^ ]+[ ]+/, "", line)
                        sub(/^\*/, "", line)
                        sub(/^.*\//, "", line)
                        if (line == want) { print hash; exit } }' "$m"
}

# ---- the out-of-band freeze log (option B) -------------------------------
# Every function below is documented as a whole in "THE OUT-OF-BAND
# FREEZE LOG" in the header. Read that first; these are the mechanics.

# Absolute, symlink-resolved directory. The freeze side and the verify
# side MUST agree on this, or a row never joins to its directory, so it
# is one function and not two call sites.
_abs_dir() {
    ( cd -- "$1" 2>/dev/null && pwd -P ) || return 1
}

# Escape a value for a JSON string. Backslash first, then quote — the
# other order would double-escape the backslash it just inserted.
# Control characters are not escaped because none of these fields can
# hold one: `name` is a bare file name, `dir` and `src` are paths, and
# `window` is a tmux window name.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# The freeze lock. One lock file, `$FREEZE_LOG.lock`, shared by every
# agent that uses the same freeze log.
#
# It is a SEPARATE file, so taking it never needs the log itself to be
# writable. It is held on a file descriptor and never explicitly
# released: process exit releases it, which is the only release that
# cannot be skipped by an `exit` in the middle of the script — and this
# script exits from nine places.
#
# It guards the WHOLE freeze, not just the log append. The manifest
# append is a `chmod u+w` → `>>` → `chmod 0440` sequence, and two
# concurrent freezes race on it: one process sets 0440 while the other
# is between its own chmod and its append, and that append fails with
# EACCES. Measured before this lock existed: 12 parallel freezes into
# one directory left 10 rows in `MANIFEST.md5`. The two lost freezes
# failed LOUDLY, with exit 4, so nothing was silently dropped — but two
# of twelve is not a rate to live with.
FREEZE_LOCK_FD=""
FREEZE_LOCK_HELD=0

# $1: `exclusive` (a freeze) or `shared` (a --verify read).
# Returns non-zero when the lock was NOT taken. The caller decides what
# to do about that; nothing here fails the run over it.
_freeze_lock_acquire() {
    local kind="${1:-exclusive}" flag="-x" lock
    [[ "$kind" == shared ]] && flag="-s"
    local log_dir="${FREEZE_LOG%/*}"
    [[ "$log_dir" == "$FREEZE_LOG" ]] && log_dir="."
    mkdir -p -- "$log_dir" 2>/dev/null || true
    lock="${FREEZE_LOG}.lock"

    # The braces are load-bearing. `exec <redir> 2>/dev/null` with no
    # command applies BOTH redirections to the shell PERMANENTLY, so a
    # bare `exec {fd}>>"$lock" 2>/dev/null` sends this script's stderr
    # to /dev/null for the rest of the run — every later warning and
    # every failure message silently dropped. Wrapping the `exec` in a
    # group scopes the `2>/dev/null` to the group; the fd the `exec`
    # opens still outlives it, which is the point.
    # flock-fd: held only for one freeze or verify run; the children spawned under it (cp, md5sum, chmod, date) exit before the script does, so no child outlives the hold.
    if ! { exec {FREEZE_LOCK_FD}>>"$lock"; } 2>/dev/null; then
        FREEZE_LOCK_FD=""
        FREEZE_LOCK_HELD=0
        return 1
    fi
    # 120 s. A freeze holds the lock across its own copy, so the wait
    # has to cover one large artefact, not one syscall.
    if command -v flock >/dev/null 2>&1 && flock "$flag" -w 120 "$FREEZE_LOCK_FD" 2>/dev/null; then
        FREEZE_LOCK_HELD=1
        return 0
    fi
    FREEZE_LOCK_HELD=0
    return 1
}

# Say, once and loudly, that this run is not serialised. A silent
# unlocked append would be a success message standing in for a check
# nobody ran — the exact shape of the incident this guard exists to
# prevent.
_freeze_lock_warn() {
    echo "evidence-freeze: WARNING: proceeding WITHOUT a lock on $(basename -- "$FREEZE_LOG")" >&2
    echo "  a concurrent freeze could interleave with this one" >&2
}

# Append one line to the freeze log, with the log writable only for the
# duration. Returns non-zero when the line did not land. Serialisation
# is the caller's: this runs inside the lock taken above.
_freeze_log_append() {
    local d="$1" n="$2" h="$3" b="$4" s="$5"
    local log_dir="${FREEZE_LOG%/*}"
    [[ "$log_dir" == "$FREEZE_LOG" ]] && log_dir="."
    mkdir -p -- "$log_dir" 2>/dev/null || {
        echo "evidence-freeze: cannot create $log_dir for $FREEZE_LOG" >&2
        return 1
    }

    local ts line
    ts=$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) || ts=""
    printf -v line \
        '{"v":%s,"ts":"%s","event":"freeze","dir":"%s","name":"%s","md5":"%s","bytes":%s,"src":"%s","window":"%s"}' \
        "$FREEZE_LOG_SCHEMA" "$ts" \
        "$(_json_escape "$d")" "$(_json_escape "$n")" "$h" \
        "${b:-0}" "$(_json_escape "$s")" \
        "$(_json_escape "${NEXUS_WORKER_WINDOW:-}")"

    local rc=0
    [[ -f "$FREEZE_LOG" ]] && { chmod u+w -- "$FREEZE_LOG" 2>/dev/null || true; }
    printf '%s\n' "$line" >> "$FREEZE_LOG" || rc=1
    chmod 0440 -- "$FREEZE_LOG" 2>/dev/null || true
    return "$rc"
}

# Emit `name<TAB>md5` for every row whose `dir` equals $1, in file
# order. Duplicates are emitted as they appear — the caller decides
# what a duplicate means.
#
# The extractor reads a JSON string value by hand rather than shelling
# out to a JSON parser, because this script may not assume one is
# installed. It requires the key to start a field (`{"k":"` or `,"k":"`)
# so that a key name occurring INSIDE another value cannot be mistaken
# for the field itself.
_freeze_log_rows() {
    local d="$1"
    [[ -f "$FREEZE_LOG" ]] || return 0
    # ENVIRON, not `awk -v`: an evidence directory whose PATH holds a
    # backslash is written to the log escaped, and `awk -v` would
    # un-escape the pattern differently, so the row would never join to
    # its own directory. Measured before this fix: a directory named
    # `ev\dir` reported "0 of 1 recorded out of band" on a file it had
    # just frozen — a false CLEAN, which is the failure mode this whole
    # check exists to remove.
    EF_WANT="$d" awk '
        function jget(line, key,   pat, n, i, c, out, esc) {
            pat = "\"" key "\":\""
            n = index(line, "{" pat)
            if (n > 0) { i = n + 1 + length(pat) }
            else {
                n = index(line, "," pat)
                if (n == 0) return ""
                i = n + 1 + length(pat)
            }
            out = ""; esc = 0
            while (i <= length(line)) {
                c = substr(line, i, 1)
                if (esc) { out = out c; esc = 0 }
                else if (c == "\\") esc = 1
                else if (c == "\"") break
                else out = out c
                i++
            }
            return out
        }
        {
            if (jget($0, "dir") != ENVIRON["EF_WANT"]) next
            n = jget($0, "name"); h = jget($0, "md5")
            if (n == "" || h == "") next
            printf "%s\t%s\n", n, h
        }
    ' "$FREEZE_LOG" 2>/dev/null
}

src=""
task=""
dir=""
as_name=""
mode="freeze"

_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}

_argloop_prev_1=-1; while (( $# )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
    case "$1" in
        --task)    task="${2:-}"; shift 2 || usage ;;
        --dir)     dir="${2:-}";  shift 2 || usage ;;
        --as)      as_name="${2:-}"; shift 2 || usage ;;
        --verify)  mode="verify"; shift ;;
        -h|--help) usage ;;
        --)        shift; src="${1:-}"; break ;;
        -*)        usage ;;
        *)         src="$1"; shift ;;
    esac
done

[[ -n "$task" || -n "$dir" ]] || usage
[[ -z "$task" || -z "$dir" ]] || {
    echo "evidence-freeze: give --task OR --dir, not both" >&2; exit 2; }
[[ -n "$dir" ]] || dir="$STATE_DIR/evidence/$task"

# ---- verify mode ---------------------------------------------------------
# Three separate checks. Each can fail on its own, and each is reported,
# so one clean line never stands for an unrun check.
if [[ "$mode" == verify ]]; then
    [[ -d "$dir" ]] || { echo "evidence-freeze: no such evidence dir: $dir" >&2; exit 2; }
    manifest="$dir/$MANIFEST_NAME"
    [[ -f "$manifest" ]] || { echo "evidence-freeze: no $MANIFEST_NAME in $dir" >&2; exit 5; }
    rc=0

    if ( cd "$dir" && md5sum -c "$MANIFEST_NAME" ); then
        :
    else
        echo "evidence-freeze: CHECKSUM MISMATCH in $dir — a frozen file has changed" >&2
        rc=5
    fi

    # Invariant 2: every frozen file is read-only. A writable freeze is a
    # freeze the next `cp` overwrites in silence.
    while read -r _sum name; do
        [[ -n "${name:-}" ]] || continue
        name="${name#\*}"
        [[ -e "$dir/$name" ]] || continue
        if [[ -w "$dir/$name" ]]; then
            echo "evidence-freeze: WRITABLE freeze: $name (want mode 0440)" >&2
            rc=5
        fi
    done < "$manifest"

    # Invariant 3: the manifest is not writable, so it cannot be
    # regenerated by a stray redirect.
    if [[ -w "$manifest" ]]; then
        echo "evidence-freeze: WRITABLE $MANIFEST_NAME — a regeneration would not fail" >&2
        rc=5
    fi

    # Invariant 4: the manifest records every regular file that is here.
    # `md5sum -c` walks the manifest, so it is blind in the other
    # direction: bytes present under a name nobody recorded pass every
    # check above. Top level only, and no name is exempt — see "EXIT 6"
    # in the header for why.
    unrecorded=0
    while IFS= read -r path; do
        base="${path##*/}"
        [[ "$base" == "$MANIFEST_NAME" ]] && continue
        _manifest_records "$manifest" "$base" && continue

        # Not recorded under a bare name. Before calling it unrecorded,
        # ask whether the manifest names this exact file some other way.
        # A path-qualified row does, and md5sum -c cannot check it from
        # inside this directory, which is why such a directory ALSO
        # reports a checksum mismatch.
        rec_hash=$(_manifest_hash_for_basename "$manifest" "$base")
        if [[ -n "$rec_hash" ]]; then
            live_hash=$(md5sum < "$dir/$base" 2>/dev/null | cut -d' ' -f1)
            if [[ "$rec_hash" == "$live_hash" ]]; then
                echo "evidence-freeze: NOTE: $base is recorded under a path-qualified name, not a bare name" >&2
                echo "  the hash matches, so these bytes ARE accounted for" >&2
                echo "  md5sum -c cannot check that row from inside this directory" >&2
            else
                echo "evidence-freeze: CONTENT MISMATCH: $base is recorded under a path-qualified name" >&2
                echo "  recorded: ${rec_hash}" >&2
                echo "  on disk:  ${live_hash:-unreadable}" >&2
                rc=5
            fi
            continue
        fi

        echo "evidence-freeze: UNRECORDED file: $base ($MANIFEST_NAME does not list it)" >&2
        unrecorded=$(( unrecorded + 1 ))
    done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)

    # Invariant 5: the out-of-band freeze log. Invariants 1 to 4 all
    # read only this directory, so a directory that was emptied and
    # rebuilt satisfies every one of them. This is the only check that
    # reads a record the same `rm` could not have taken. Full rule and
    # its limits: "THE OUT-OF-BAND FREEZE LOG" in the header.
    crosscheck=0
    if [[ -f "$FREEZE_LOG" && -w "$FREEZE_LOG" ]]; then
        echo "evidence-freeze: WRITABLE $(basename -- "$FREEZE_LOG") — a regeneration would not fail" >&2
        rc=5
    fi

    # A SHARED lock, so several `--verify` runs do not block each other
    # but none of them reads a line a freeze is halfway through writing.
    # A torn last line would parse as no row at all, and the file it
    # named would silently drop to "uncovered" — a false clean.
    _freeze_lock_acquire shared || _freeze_lock_warn

    abs_dir=$(_abs_dir "$dir") || abs_dir="$dir"
    declare -A _logged_md5=()
    logged_names=()
    while IFS=$'\t' read -r lname lhash; do
        [[ -n "${lname:-}" ]] || continue
        if [[ -n "${_logged_md5[$lname]:-}" ]]; then
            # This script cannot write two rows for one name: the
            # target refuses to be clobbered and the manifest refuses
            # the name. A duplicate is the bypass, run THROUGH this
            # script rather than around it.
            echo "evidence-freeze: DUPLICATE freeze-log entry for $lname in $abs_dir" >&2
            echo "  a name is frozen once. Two rows mean the directory was emptied and re-frozen." >&2
            crosscheck=$(( crosscheck + 1 ))
        else
            logged_names+=( "$lname" )
        fi
        _logged_md5[$lname]="$lhash"
    done < <(_freeze_log_rows "$abs_dir")

    for lname in "${logged_names[@]:-}"; do
        [[ -n "$lname" ]] || continue
        if [[ ! -f "$dir/$lname" ]]; then
            echo "evidence-freeze: LOGGED FREEZE MISSING: $lname" >&2
            echo "  $(basename -- "$FREEZE_LOG") records this freeze; it is not in $dir" >&2
            echo "  recorded: ${_logged_md5[$lname]}" >&2
            crosscheck=$(( crosscheck + 1 ))
            continue
        fi
        live_bytes=$(md5sum < "$dir/$lname" 2>/dev/null | cut -d' ' -f1)
        if [[ "$live_bytes" != "${_logged_md5[$lname]}" ]]; then
            echo "evidence-freeze: FREEZE-LOG MISMATCH: $lname" >&2
            echo "  recorded out of band: ${_logged_md5[$lname]}" >&2
            echo "  on disk:              ${live_bytes:-unreadable}" >&2
            crosscheck=$(( crosscheck + 1 ))
        fi
    done

    # Coverage. Per FILE, never per directory: a directory that predates
    # the freeze log gains coverage one freeze at a time. This line is
    # printed on every run, clean or not, so a clean verdict can never
    # be mistaken for a cross-checked one.
    covered=0
    total=0
    while IFS= read -r path; do
        base="${path##*/}"
        [[ "$base" == "$MANIFEST_NAME" ]] && continue
        total=$(( total + 1 ))
        [[ -n "${_logged_md5[$base]:-}" ]] && covered=$(( covered + 1 ))
    done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)

    if [[ -f "$FREEZE_LOG" ]]; then
        echo "evidence-freeze: freeze-log cross-check: $covered of $total top-level file(s) recorded out of band" >&2
    else
        echo "evidence-freeze: freeze-log cross-check: no $FREEZE_LOG — 0 of $total top-level file(s) recorded out of band" >&2
    fi
    if (( covered < total )); then
        echo "  $(( total - covered )) file(s) have NO out-of-band record, so this check cannot cover them" >&2
        echo "  that is not an error: it is what a directory frozen before the log looks like" >&2
    fi

    if (( unrecorded > 0 )); then
        echo "evidence-freeze: $unrecorded unrecorded file(s) in $dir — freeze them, or they are not evidence" >&2
    fi

    # Precedence: 5, then 8, then 6.
    #
    # 5 is first because a broken invariant is the graver finding and
    # because it is the one a reader can act on without any other file.
    # 8 outranks 6 because a disagreement with the out-of-band record
    # says the STORED BYTES are wrong, while 6 says only that a file
    # nobody recorded is sitting there.
    #
    # This ordering also means exit 8 marks exactly the case no other
    # check can reach: a directory that is internally consistent and
    # still wrong.
    if (( rc == 0 )) && (( crosscheck > 0 )); then rc=8; fi
    if (( rc == 0 )) && (( unrecorded > 0 )); then rc=6; fi

    (( rc == 0 )) && echo "evidence-freeze: $dir verified clean (freeze-log covers $covered of $total)"
    exit "$rc"
fi

# ---- freeze mode ---------------------------------------------------------
[[ -n "$src" ]] || usage
[[ -f "$src" ]] || { echo "evidence-freeze: not a readable file: $src" >&2; exit 2; }
[[ -n "$as_name" ]] || as_name=$(basename -- "$src")
case "$as_name" in
    */*|"") echo "evidence-freeze: --as takes a bare file name, not a path: $as_name" >&2; exit 2 ;;
    "$MANIFEST_NAME") echo "evidence-freeze: refusing to freeze over $MANIFEST_NAME" >&2; exit 2 ;;
esac

# `-m 0770` applies to directories this command CREATES, and leaves an
# existing directory's mode alone. Without it the mode is whatever the
# caller's umask leaves, which is not a mode any test can assert.
#
# THIS IS A FIXED MODE, AND IT CUTS BOTH WAYS. Measured old (umask-
# derived) against new (fixed) at each umask:
#
#     umask   old   new   direction
#     0007    770   770   unchanged — the umask in use here
#     0000    777   770   tightened
#     0022    755   770   `o` tightened, `g` GAINS w
#     0027    750   770   `g` GAINS w
#     0077    700   770   `g` GAINS rwx
#
# Under a restrictive umask this WIDENS the directory, and directory
# write permission is exactly what the remove-and-recreate bypass above
# needs. On this host nothing changes, because the umask is 0007 and the
# group is the operator's own. Elsewhere it would. `0700` would never
# widen, but it would break any setup that reads the state tree by
# group, so the fixed value is the operator's call, not this script's.
mkdir -p -m 0770 "$dir" || { echo "evidence-freeze: cannot create $dir" >&2; exit 2; }
target="$dir/$as_name"
manifest="$dir/$MANIFEST_NAME"

# Take the freeze lock BEFORE the clobber check, so the whole
# check-copy-record sequence is one critical section. Held to process
# exit; see the lock's own comment above for why it covers the copy and
# not just the two appends.
_freeze_lock_acquire exclusive || _freeze_lock_warn

# 1. Refuse to clobber. Print the existing file's hash so the caller can
#    tell "already frozen, identical" from "a different artefact wants
#    this name" without touching anything.
if [[ -e "$target" ]]; then
    existing=$(md5sum < "$target" 2>/dev/null | cut -d' ' -f1)
    incoming=$(md5sum < "$src" 2>/dev/null | cut -d' ' -f1)
    {
        echo "evidence-freeze: REFUSED — $as_name already exists in $dir"
        echo "  existing: ${existing:-unreadable}"
        echo "  incoming: ${incoming:-unreadable}"
        echo "  A freeze is write-once. Pick a name that marks THIS pass, e.g."
        echo "  --as '${as_name%.*}.$(date +%Y%m%dT%H%M%S).${as_name##*.}'"
    } >&2
    exit 3
fi

# The manifest can record a name whose file was removed. Appending a
# second entry for it would leave two rows for one name, so refuse.
if _manifest_records "$manifest" "$as_name"; then
    echo "evidence-freeze: REFUSED — $MANIFEST_NAME already records '$as_name' in $dir" >&2
    exit 4
fi

# 2. Copy WITHOUT -p: the frozen file's mtime must be the freeze time.
if ! cp -- "$src" "$target"; then
    echo "evidence-freeze: copy failed: $src -> $target" >&2
    rm -f -- "$target"
    exit 2
fi
# Read the mode back. A swallowed chmod failure would leave a WRITABLE
# freeze under a script that prints `mode 0440`. Nothing is recorded
# yet, so the safe answer is to undo the copy and fail loudly.
chmod 0440 -- "$target" 2>/dev/null
if ! _mode_is "$target" 440; then
    {
        echo "evidence-freeze: FAILED to set mode 0440 on $target"
        echo "  mode is now: $(stat -c '%a' -- "$target" 2>/dev/null || echo unreadable)"
        echo "  A writable freeze is not a freeze. The copy was removed; nothing was recorded."
    } >&2
    rm -f -- "$target"
    exit 7
fi

# 3. Append to the manifest, never regenerate it. The manifest is held
#    read-only between appends, so a stray `md5sum … > MANIFEST.md5`
#    fails with EACCES rather than rewriting the record.
if [[ -f "$manifest" ]]; then
    chmod u+w -- "$manifest" 2>/dev/null || true
fi
if ! ( cd "$dir" && md5sum -- "$as_name" >> "$MANIFEST_NAME" ); then
    echo "evidence-freeze: could not append to $manifest — freeze left in place, NOT recorded" >&2
    chmod 0440 -- "$manifest" 2>/dev/null || true
    exit 4
fi
chmod 0440 -- "$manifest" 2>/dev/null

frozen_md5=$(tail -1 "$manifest" | cut -d' ' -f1)

# 4. Record the freeze OUT OF BAND. This runs AFTER the manifest append,
#    so the log never claims a freeze the manifest does not carry. The
#    reverse order would leave a row for bytes that failed to be
#    recorded, and a record that overstates is worse than none.
#
#    A failure here does NOT undo the freeze: the bytes are copied,
#    read-only and recorded in the manifest, and throwing that away
#    would destroy evidence to report a bookkeeping failure. It exits 8
#    instead, and says plainly which promise went unmet.
log_rc=0
_freeze_log_append \
    "$(_abs_dir "$dir" || printf '%s' "$dir")" \
    "$as_name" "$frozen_md5" \
    "$(stat -c '%s' -- "$target" 2>/dev/null || echo 0)" \
    "$(readlink -f -- "$src" 2>/dev/null || printf '%s' "$src")" \
    || log_rc=$?

printf 'frozen %s -> %s\n' "$src" "$target"
printf 'md5    %s\n' "$frozen_md5"

if (( log_rc != 0 )); then
    {
        echo "evidence-freeze: FAILED to record this freeze in $FREEZE_LOG"
        echo "  The freeze is kept and $MANIFEST_NAME records it."
        echo "  It has NO out-of-band record, so --verify cannot cross-check it:"
        echo "  a later remove-and-recreate of $as_name would not be detected."
    } >&2
    exit 8
fi

# The freeze IS recorded by this point, so a failure here is not a
# reason to undo it. It is a reason not to claim the manifest is
# protected. Report the mode that is actually set.
if ! _mode_is "$manifest" 440; then
    {
        echo "evidence-freeze: FAILED to set mode 0440 on $manifest"
        echo "  mode is now: $(stat -c '%a' -- "$manifest" 2>/dev/null || echo unreadable)"
        echo "  The freeze is recorded. The manifest is NOT protected:"
        echo "  a stray 'md5sum … > $MANIFEST_NAME' would rewrite it."
    } >&2
    exit 7
fi

# Same rule for the freeze log: report the mode that is actually set,
# never the mode this script asked for. A writable log is one stray `>`
# away from losing every record it holds — for every evidence directory,
# not just this one.
if ! _mode_is "$FREEZE_LOG" 440; then
    {
        echo "evidence-freeze: FAILED to set mode 0440 on $FREEZE_LOG"
        echo "  mode is now: $(stat -c '%a' -- "$FREEZE_LOG" 2>/dev/null || echo unreadable)"
        echo "  The freeze is recorded, in $MANIFEST_NAME and out of band."
        echo "  The freeze log is NOT protected: a stray '>' would rewrite it,"
        echo "  and it holds the records for every evidence directory."
    } >&2
    exit 7
fi
printf 'mode   0440 (read-only); %s is append-only\n' "$MANIFEST_NAME"
printf 'logged %s\n' "$FREEZE_LOG"
exit 0
