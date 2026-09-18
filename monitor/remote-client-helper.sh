#!/usr/bin/env bash
# remote-client-helper.sh — emit the CURRENT client-side helper set, with
# integrity digests computed AT CALL TIME.
#
# WHY THIS EXISTS (your-org/nexus-code, "the stale sha256"). The client-helper
# delivery flow used to have the orchestrator recite a sha256 to the client by
# hand, out-of-band. A literal digest in a document — or in an orchestrator's
# memory — is correct when written and wrong forever after, and the failure is
# SILENT IN BOTH DIRECTIONS: the client verifies the copy it received against
# the stale value it was given, both sides agree, and the client confidently
# installs an old helper. Measured instance: a client verified against a digest
# whose blob was FOUR revisions behind the shipped one, and reported success.
#
# The defect is the literal, not the client. So there is no literal: this verb
# reads the files that exist RIGHT NOW and hashes them RIGHT NOW. Docs point at
# the verb instead of quoting a value, and nobody transcribes a digest again.
#
# WHAT A DIGEST DOES AND DOES NOT ESTABLISH — say this every time, because a
# client that is not told will reasonably assume otherwise. When the SAME party
# supplies both the artifact and its digest, the digest proves exactly one
# thing: THE BYTES SURVIVED TRANSIT UNCORRUPTED. It authenticates nothing. It
# is not a signature, it attests nothing about provenance, and it establishes
# no benignity. A client that matches the digest has ruled out a mangled copy
# and NOTHING ELSE; source review is still owed, and is the client's job. That
# paragraph is emitted with every manifest for exactly that reason.
#
# THE SET IS A SET, NOT A FILE. `nexus-request` and `nexus-reply-watch` each
# source `_nexus_watch_lib.sh` from beside themselves (converged on one
# watch-loop core). Delivering one script alone yields a helper that cannot
# run. The runtime failure is loud and actionable — both scripts print
# `cannot load _nexus_watch_lib.sh (expected next to this script)` and exit 64,
# which is why this is a DELIVERY defect and not a script defect — but a loud
# failure at the client is still a round trip the delivery should not cost.
# So this verb ships the whole set, always, and `--base64` reconstructs it
# with modes intact in one paste.
#
# Usage:
#   remote-client-helper.sh                 manifest: paths, bytes, sha256 (now)
#   remote-client-helper.sh --base64        one-paste installer (tar.gz, b64) + manifest
#   remote-client-helper.sh --files         bare paths, one per line (scripting seam)
#   remote-client-helper.sh --verify DIR    check an installed DIR against the current set
#
# NON-SECRET by construction: these are tracked, world-readable source files.
# Nothing here reads the principals dir, a key, or a token — so unlike the rest
# of `ng remote`, this output carries no out-of-band handling burden.
#
# Exit codes: 0 ok · 1 usage · 2 a helper file is missing/unreadable ·
#   3 --verify found a divergence · 4 dependency missing (sha256, tar, base64).

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PROG=remote-client-helper
die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# The set, in delivery order (library last — it is sourced, never invoked).
# Kept as an explicit list rather than a glob: a glob would silently widen the
# delivered set the moment anything else lands in monitor/client/, and "what
# gets handed to a remote client" must be a decision, not a directory listing.
HELPERS=(nexus-request nexus-reply-watch _nexus_watch_lib.sh)
CLIENT_DIR="$_script_dir/client"

# sha256 over a file, portable across sha256sum / shasum / openssl. Prints the
# hex only. Fails (rc 1) rather than printing something that is not a digest —
# an empty or partial digest presented as one is the defect class this whole
# script exists to close.
_sha256_of() {
    local f="$1" h=""
    if   command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum   < "$f" 2>/dev/null | awk '{print $1}')
    elif command -v shasum    >/dev/null 2>&1; then h=$(shasum -a 256 < "$f" 2>/dev/null | awk '{print $1}')
    elif command -v openssl   >/dev/null 2>&1; then h=$(openssl dgst -sha256 < "$f" 2>/dev/null | awk '{print $NF}')
    else return 1
    fi
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$h"
}

# Resolve + validate the set. Fails CLOSED: a missing or unreadable member is
# an error, never a quietly shorter manifest. A manifest that lists two of
# three files looks exactly like a set that has two files.
_require_set() {
    local n missing=""
    for n in "${HELPERS[@]}"; do
        [[ -r "$CLIENT_DIR/$n" ]] || missing="${missing:+$missing }$n"
    done
    [[ -z "$missing" ]] || {
        printf '%s: MISSING or unreadable helper(s) in %s: %s\n' "$PROG" "$CLIENT_DIR" "$missing" >&2
        printf '  The helper set is delivered whole; refusing to emit a partial manifest.\n' >&2
        exit 2
    }
}

_provenance() {
    # Report the ref the digests describe. A digest is a property of a TREE:
    # quoted without its ref it identifies nothing, and carried to another
    # checkout it silently describes something else.
    local ref="(not a git checkout)"
    if git -C "$_script_dir" rev-parse --short HEAD >/dev/null 2>&1; then
        ref=$(git -C "$_script_dir" rev-parse --short HEAD 2>/dev/null)
        git -C "$_script_dir" diff --quiet -- "$CLIENT_DIR" 2>/dev/null || ref="$ref+dirty"
    fi
    printf '%s' "$ref"
}

_integrity_note() {
    cat <<'NOTE'
What these digests DO and DO NOT establish
------------------------------------------
They were computed just now, from the files as they exist in this checkout, so
they cannot be stale. That is the ONE problem they solve.

They are NOT an authentication. The same party is handing you both the files
and the digests, so a match proves only that THE BYTES SURVIVED TRANSIT
UNCORRUPTED. It is not a signature. It attests nothing about who wrote the
code, and it establishes NOTHING about whether the code is benign.

Reviewing the source before you run it remains YOUR job, and a matching digest
does not discharge it. These are short POSIX-sh scripts, meant to be read. A
client that has actually reviewed them can say so specifically — for example:
the only `.` sources the companion library at a fixed path beside the script
and never reply bytes; the frontmatter parser accepts a fixed key allowlist;
outbound calls are limited to the pinned `ssh` invocation; no `eval`, no
pipe-to-shell, no persistence, no phone-home; `sh -n` clean. Say what you
checked, not that you checked.
NOTE
}

_manifest() {
    local n h b ref; ref=$(_provenance)
    printf 'nexus client helper set — %d files, digests computed at call time\n' "${#HELPERS[@]}"
    printf 'source ref: %s   (digests describe THIS tree)\n\n' "$ref"
    for n in "${HELPERS[@]}"; do
        h=$(_sha256_of "$CLIENT_DIR/$n") || { warn "no usable sha256 tool (need sha256sum/shasum/openssl)"; exit 4; }
        b=$(wc -c < "$CLIENT_DIR/$n" | tr -d ' ')
        printf '  %-22s  %10s bytes  sha256 %s\n' "$n" "$b" "$h"
    done
    printf '\nAll three go in ONE directory. `nexus-request` and `nexus-reply-watch`\n'
    printf 'source `_nexus_watch_lib.sh` from beside themselves; either script\n'
    printf 'installed alone exits 64 with "cannot load _nexus_watch_lib.sh".\n'
    printf '\nVerify an install (run in the directory holding the three files):\n'
    printf '  sha256sum nexus-request nexus-reply-watch _nexus_watch_lib.sh\n\n'
    _integrity_note
}

_base64_block() {
    command -v tar    >/dev/null 2>&1 || { warn "tar not found"; exit 4; }
    command -v base64 >/dev/null 2>&1 || { warn "base64 not found"; exit 4; }
    local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/nxhelper.XXXXXX") || die "mktemp failed"
    # -h dereferences, --mode normalises: the client gets executable scripts and
    # a plain-mode library regardless of how this checkout is grouped (the nexus
    # tree is group-shared lab storage, so source modes are not a good default
    # to propagate to a client's key directory).
    tar -C "$CLIENT_DIR" -czf "$tmp/set.tgz" "${HELPERS[@]}" 2>/dev/null \
        || { rm -rf "$tmp"; die "tar failed over $CLIENT_DIR"; }
    printf '# One-paste install of the nexus client helper set.\n'
    printf '# Creates ./nexus-helpers/ with all %d files. Review the source BEFORE running\n' "${#HELPERS[@]}"
    printf '# anything from it — see the note under the manifest below.\n'
    printf 'mkdir -p nexus-helpers && base64 -d <<'"'"'B64EOF'"'"' | tar -xzf - -C nexus-helpers\n'
    base64 < "$tmp/set.tgz"
    printf 'B64EOF\n'
    printf 'chmod 700 nexus-helpers/nexus-request nexus-helpers/nexus-reply-watch\n'
    printf 'chmod 600 nexus-helpers/_nexus_watch_lib.sh\n\n'
    rm -rf "$tmp"
    _manifest
}

_verify_dir() {
    local dir="$1" n h g rc=0
    [[ -d "$dir" ]] || die "--verify: not a directory: $dir"
    for n in "${HELPERS[@]}"; do
        if [[ ! -r "$dir/$n" ]]; then
            printf '  %-22s  MISSING at %s\n' "$n" "$dir"; rc=3; continue
        fi
        h=$(_sha256_of "$CLIENT_DIR/$n") || { warn "no usable sha256 tool"; exit 4; }
        g=$(_sha256_of "$dir/$n")        || { warn "cannot hash $dir/$n"; exit 4; }
        if [[ "$h" == "$g" ]]; then
            printf '  %-22s  ok\n' "$n"
        else
            printf '  %-22s  DIVERGED  installed=%s current=%s\n' "$n" "${g:0:12}" "${h:0:12}"; rc=3
        fi
    done
    if (( rc == 0 )); then
        printf '\nAll %d match this checkout (%s). Transit integrity only — see the note in\n' \
            "${#HELPERS[@]}" "$(_provenance)"
        printf '`%s` (no --verify) for what that does and does not establish.\n' "$PROG"
    else
        printf '\nDivergence or absence above: re-deliver the CURRENT set with\n'
        printf '  monitor/ng remote client-helper --base64\n'
    fi
    return $rc
}

case "${1:---manifest}" in
    --manifest|"") _require_set; _manifest ;;
    --base64)      _require_set; _base64_block ;;
    --files)       _require_set; printf '%s\n' "${HELPERS[@]/#/$CLIENT_DIR/}" ;;
    --verify)      [[ -n "${2:-}" ]] || die "--verify needs a directory"; _require_set; _verify_dir "$2" ;;
    -h|--help)     sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)             die "unknown flag: $1 (--manifest|--base64|--files|--verify DIR|--help)" ;;
esac
