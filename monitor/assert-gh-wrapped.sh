#!/usr/bin/env bash
# monitor/assert-gh-wrapped.sh — DEPRECATED COMPATIBILITY WRAPPER.
#
# The `gh`-only spawn-time precondition introduced in your-org/nexus-code#578
# was generalised in #589 to cover EVERY PATH-front shim this nexus ships
# (monitor/*wrap → gh, pip, pip3, sandbox-notify, …), plus an observed check
# that the worker's RLIMIT_NPROC ceiling actually reaches its children. The
# reason for generalising is in the successor's header: the PATH root cause is
# not `gh`-specific, and the OTHER shims fail in the opposite direction — an
# unwrapped `gh` is fail-safe by accident (no ambient credentials), an unwrapped
# `pip` is fail-OPEN and its blast radius is every user on the node (#487).
#
# This file remains only so that an out-of-tree caller — a fork, an older
# operator checkout, a stale launcher generated before the rename — keeps
# working instead of silently skipping the check (every in-tree launcher tests
# `[ -x … ]` before calling, so a hard removal would degrade to NO check at
# all, which is the exact failure class #589 is about). It forwards verbatim.
#
# New callers: use monitor/assert-shims-wrapped.sh directly.

set -u

_agw_self_dir=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _agw_self_dir="."
_agw_next="$_agw_self_dir/assert-shims-wrapped.sh"

if [ ! -x "$_agw_next" ]; then
    # Mixed checkout: this shim is present but its successor is not. Allow the
    # spawn — refusing would halt every spawn over a packaging problem — but
    # report it as the THIRD OUTCOME, 79, never 0 (your-org/nexus-code#612).
    #
    # This branch used to print the words "NOT checked" and then return the
    # same value as a clean pass, which is the defect #612 exists to close,
    # surviving inside the forwarder written during the rename. It is not
    # hypothetical: it is exactly the partially-pulled tree #614 describes —
    # this file present, its successor not — and it is the ONE state the
    # successor cannot adjudicate on its own behalf, because it is absent. So
    # 79 here is the forwarder answering for itself, not a second copy of a
    # contract that belongs downstream; everything else still `exec`s.
    printf 'assert-gh-wrapped: NOT CHECKED: successor %s missing — shim/nproc preconditions were not verified for this spawn (mixed checkout).\n' \
        "$_agw_next" >&2
    printf 'assert-gh-wrapped: this is not a pass. Bring the checkout that owns this tree up to date (your-org/nexus-code#614).\n' >&2
    exit 79
fi

exec "$_agw_next" "$@"
