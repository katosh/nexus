#!/usr/bin/env bash
# _tmux_socket.sh — the tmux SOCKET-PATH ceiling, measured in one place.
# (your-org/nexus-code#991)
#
# THE DEFECT THIS EXISTS TO END. A UNIX-domain socket path lives in
# `struct sockaddr_un.sun_path`, which is 108 bytes, and the longest path any
# ordinary caller can bind is **107**. tmux composes its socket path as
#
#     ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<socket-name>
#
# and a session-scratchpad-length `TMUX_TMPDIR` is ALREADY over the limit
# before the suffix is appended. Every `tmux -L <name>` call then dies with
#
#     error connecting to <path> (File name too long)
#
# which a suite reads as "tmux is unavailable", takes its precondition branch,
# and reports as a FAIL. Five suites went red that way in one session, five
# attributions were wrong, and one published finding had to be retracted
# (`your-org/nexus-code#897#issuecomment-5404755941`).
#
# WHY IT IS WORSE THAN A FLAKE, and why a helper rather than a note. It
# reproduces IDENTICALLY on every tree, so the standard triage — "does this
# also fail on clean `dev`?" — answers YES, and a reasonable person reads that
# as "pre-existing defect, not mine". It actually means "the apparatus is
# broken in both". Those are opposite conclusions and the observation cannot
# separate them. That is `#828`'s rule applied to the HARNESS: vary the axis
# the mechanism varies on, and the harness is the axis nobody thinks to vary.
#
# THE GUIDANCE AND THE CONSTRAINT COLLIDE. The workspace rule is never to touch
# the shared tmux server, so isolating with a private `TMUX_TMPDIR` is CORRECT
# advice — and the natural place to point it (the session scratchpad) is
# already too long. Nothing warns you; you just get reds.
#
# ---------------------------------------------------------------------------
# MEASURED ON THIS HOST, not asserted. tmux 2.6, uid 71780, Linux 5.4.0:
#
#   * python `socket.bind` on a 107-byte path succeeds; 108 fails
#     `AF_UNIX path too long`. Same boundary through tmux itself: a composed
#     socket path of 107 bytes starts a server, 108 gives
#     `error connecting to … (File name too long)`.
#     ==> THE USABLE MAXIMUM IS 107, NOT 108. A guard written to the
#         "108-byte limit" everyone quotes is OFF BY ONE and passes exactly
#         the boundary path that fails.
#
#   * BUT THE MECHANISM IS THE CALLING CONVENTION, NOT THE KERNEL, and the
#     first draft of this comment got that wrong. Measured in C on this host,
#     varying ONLY `addrlen`:
#
#         len=107  addrlen=offsetof+strlen+1 -> BIND    addrlen=sizeof(struct) -> BIND
#         len=108  addrlen=offsetof+strlen+1 -> EINVAL  addrlen=sizeof(struct) -> BIND
#         len=109  path does not fit in sun_path at all
#
#     So 108 IS bindable by the kernel; what fails at 108 is the NUL-TERMINATED
#     convention, because there is no room for the terminator. Every practical
#     caller uses that convention — tmux, python, this repo — so 107 is the
#     right number to ship. But reasoning that says "the kernel rejects 108"
#     does not generalise, and a reader who inherits it will be wrong about
#     some other caller. (Found by an independent re-derivation that was asked
#     to refute this file, and reproduced here before the wording was changed.)
#
#     Note also that the errno differs by WHO refuses. The kernel gives EINVAL
#     at 108; tmux and python refuse in USERSPACE and say "File name too long"
#     / "AF_UNIX path too long". Matching on the message is matching on the
#     caller, not on the limit.
#
#   * `TMPDIR` does NOT participate. With `TMUX_TMPDIR` unset and
#     `TMPDIR=/tmp/c71780/tmpdirprobe`, the socket landed at
#     `/tmp/tmux-71780/probeA`. Only `TMUX_TMPDIR`, else `/tmp`.
#
#   * `-L` HONOURS `TMUX_TMPDIR` EVEN WHEN `$TMUX` IS SET. Measured inside a
#     live pane (`TMUX=/tmp/tmux-71780/default,12,0`): `TMUX_TMPDIR=$T tmux -L
#     wt new-session` created `$T/tmux-71780/wt`. This matters because the
#     socket-precedence rule recorded elsewhere in this repo — `-L`/`-S` >
#     `$TMUX` > `TMUX_TMPDIR` > default (`#644`) — is about WHICH SERVER a
#     bare call reaches, not about which DIRECTORY an explicit `-L` resolves
#     in. Reading it as the latter would make this computation look unsound
#     for exactly the callers it is written for.
#
# COVERAGE BOUNDARY, one sentence: this computes the path for an explicit
# `tmux -L <name>` and for a bare `tmux` whose `$TMUX` is unset; it says
# NOTHING about `tmux -S <path>` (which names the socket outright and needs no
# composition) and nothing about a bare call inside a pane (where `$TMUX`
# supplies the socket and `TMUX_TMPDIR` is not consulted at all).

# The longest path that can be bound. 108-byte sun_path, minus the NUL.
TMUX_SUN_PATH_MAX=107

# tmux_socket_path <socket-name> [<tmux-tmpdir>]
#
# Print the exact filesystem path `tmux -L <socket-name>` will use. The second
# argument defaults to the AMBIENT `TMUX_TMPDIR`, which is the whole point:
# the failure is caused by a value the caller inherited rather than chose.
tmux_socket_path() {
    local name="${1:?tmux_socket_path: socket name required}"
    local dir="${2-${TMUX_TMPDIR:-/tmp}}"
    [ -n "$dir" ] || dir=/tmp
    printf '%s/tmux-%s/%s' "$dir" "$(id -u)" "$name"
}

# tmux_socket_len <socket-name> [<tmux-tmpdir>]  -> byte length of that path
tmux_socket_len() {
    tmux_socket_path "$@" | LC_ALL=C wc -c | tr -d ' '
}

# tmux_socket_verdict <socket-name> [<tmux-tmpdir>]
#
# rc 0  the path FITS      — prints `fits <len>/107 <path>`
# rc 3  the path IS TOO LONG — prints `too-long <len>/107 <path>`
#
# Deliberately prints the MEASURED LENGTH on both arms. The cost of `#991` was
# entirely rediscovery: the number nobody printed is the number every reader
# had to re-derive, and four of them derived "tmux is broken" instead.
tmux_socket_verdict() {
    local name="${1:?tmux_socket_verdict: socket name required}" dir="${2-${TMUX_TMPDIR:-/tmp}}"
    local p len
    p=$(tmux_socket_path "$name" "$dir")
    len=$(printf '%s' "$p" | LC_ALL=C wc -c | tr -d ' ')
    if [ "$len" -le "$TMUX_SUN_PATH_MAX" ]; then
        printf 'fits %s/%s %s\n' "$len" "$TMUX_SUN_PATH_MAX" "$p"
        return 0
    fi
    printf 'too-long %s/%s %s\n' "$len" "$TMUX_SUN_PATH_MAX" "$p"
    return 3
}

# tmux_socket_short_tmpdir [<tag>]
#
# A private TMUX_TMPDIR that CANNOT blow the ceiling: `/tmp/tmux-th-<uid>-<tag>`.
# Not `$TMPDIR`, not the scratchpad, not `mktemp -d -p "$PWD"` — every one of
# those is a path whose length is decided by something other than this code,
# which is the defect. Creating it is the caller's job (`mkdir -p`), because a
# helper that has a side effect is one a measurement cannot use.
tmux_socket_short_tmpdir() {
    printf '/tmp/tmux-th-%s-%s' "$(id -u)" "${1:-$$}"
}
