#!/usr/bin/env bash
# _tmux-fixture.sh — run a test fixture against a PRIVATE tmux server, and
# know that you did (your-org/nexus-code#1105, #1025, #1027, #991).
#
# WHY THIS FILE EXISTS. A suite that needs a real tmux server must not touch
# the operator's board: bwrap is PID 1 running tmux under `--die-with-parent`,
# so ending that server ends the sandbox, and `#745` is a one-command way to
# end it. The natural way to isolate — write a `tmux` shim that pins `-L
# <private-socket>` and put its directory on the front of $PATH — IS DEFEATED
# IN THIS WORKSPACE, silently, and the failure has fired.
#
# THE MECHANISM, measured on this host (see the header of
# test-paste-dead-pane-guard.sh for the full derivation):
#
#   * $BASH_ENV is exported for every agent process and force-fronts
#     monitor/tmuxwrap ahead of whatever $PATH the caller supplied. So inside
#     any NEW `bash -c` — the shape a suite uses to drive extracted code — a
#     bare `tmux` is the WRAPPER, not the fixture's shim.
#   * tmuxwrap then resolves "the first $PATH tmux that is not a wrapper". Its
#     gate-3 classifies a candidate as a wrapper if the candidate's first 40
#     lines NAME the wrapper. A fixture shim built from `TMUX_BIN=$(command -v
#     tmux)` interpolates the wrapper's own path into its body — so gate-3
#     SKIPS THE FIXTURE'S SHIM and falls through to the real tmux WITH NO -L.
#   * `$TMUX` outranks `$TMUX_TMPDIR` (`#644`), and an agent's shell has $TMUX
#     set to the board's socket. So the unpinned client lands on THE BOARD.
#
# That is not hypothetical. On 2026-08-27 test-paste-dead-pane-guard.sh's
# part-C main.sh leg targeted the window NAME `orchestrator`, reached the
# operator's server where that name is bound and LIVE, and pasted AND SUBMITTED
# its fixture payload into the live orchestrator pane — four arrivals as
# user-role turns in 31 s, recovered from the orchestrator's session
# transcript. A test harness performed prompt injection into a running agent.
#
# THE FIX IS BELT, BRACES AND AN ALARM. Any one of them alone has already been
# shown to be out-raceable:
#
#   BELT   resolve the REAL tmux BINARY (nx_real_tmux_bin) and build the shim
#          from that, so the shim no longer names the wrapper, gate-3 no longer
#          skips it, and the -L pin is actually reached.
#   BRACES scrub $TMUX and point $TMUX_TMPDIR at a private dir, so a pin lost
#          to some FUTURE force-front lands on a private, absent socket and
#          errors — instead of on the board.
#   ALARM  nx_assert_tmux_pinned: ask, from inside the same `bash -c` shape the
#          suite uses, which socket the code under test would actually reach,
#          and fail LOUDLY if it is not the fixture's. A displaced pin must be
#          RED, not silent. This is the half that generalises: the belt fixes
#          today's force-front, the alarm catches the next one.
#
# Sourced explicitly (it is not part of _test_helpers.sh) because it has a
# single, narrow purpose and a much smaller audience than the assertion
# primitives.

# nx_real_tmux_bin — the first $PATH `tmux` that is a real BINARY, never a
# shell-script wrapper. Prints the path, rc 0; rc 1 if there is none.
#
# The discriminator is `#!`, not a name or a directory, and that is deliberate:
# it is the one property no wrapper can shed while remaining a wrapper, and it
# needs no list of wrapper paths to keep up to date. Three suites carry a
# byte-identical private copy of this function (test-absent-evidence-
# precedence.sh, test-pane-state-boot-absent.sh, test-pane-state-claude-
# identity.sh); this is the shared definition #1105 asked for. Their copies are
# left in place — each is self-contained by design, and de-duplicating them is
# a separate change with its own review surface.
nx_real_tmux_bin() {
    # TWO ZSH DIVERGENCES, BOTH FIXED HERE (your-org/nexus-code#1319). This
    # body is byte-identical in four places (see the note above); keep it so.
    #
    # (1) THE SPLIT. `for _d in $PATH` under `IFS=:` is a BASH-ONLY idiom —
    #     zsh does not word-split an unquoted parameter, so the loop ran ONCE
    #     over the whole PATH string, every candidate test failed, and the
    #     function returned 1: "no real tmux BINARY on PATH" on a host that
    #     has one. Callers spell rc 1 as `exit 77` SKIP, so the failure was
    #     coverage silently leaving the population. Measured, interpreter the
    #     only variable and $PATH pinned identical: bash -> /usr/bin/tmux,
    #     zsh -> rc 1. Parameter expansion splits identically in both shells
    #     and needs no IFS bookkeeping at all.
    #
    # (2) THE MAGIC BYTES, and this one is worse — `read -N` DOES NOT EXIST
    #     IN ZSH (`zsh:read:1: bad option: -N`, rc 1), so the old `||
    #     _magic=""` arm fails OPEN toward "this is a real binary". Repairing
    #     only the split would therefore have turned a silent SKIP into a
    #     silent WRONG ANSWER: measured, the split-repaired body under zsh
    #     returns `monitor/tmuxwrap/tmux` — the wrapper — and a shim written
    #     from that names the wrapper, loses its `-L` pin, and reaches the
    #     operator's live board, which is the 2026-08-27 mechanism this
    #     file's header exists to prevent. `head -c 2` behaves identically in
    #     both shells, and `|| continue` is fail-CLOSED: a candidate whose
    #     bytes cannot be read is treated as a wrapper and skipped.
    local _d _magic _rest="$PATH:"
    while [ -n "$_rest" ]; do
        _d="${_rest%%:*}"; _rest="${_rest#*:}"
        [ -n "$_d" ] && [ -x "$_d/tmux" ] && [ ! -d "$_d/tmux" ] || continue
        _magic=$(head -c 2 -- "$_d/tmux" 2>/dev/null) || continue
        [ "$_magic" = '#!' ] || { printf '%s' "$_d/tmux"; return 0; }
    done
    return 1
}

# nx_tmux_fixture_init <workdir> — BRACES. Point this process (and every child)
# at a private TMUX_TMPDIR and scrub $TMUX, so that a client which loses its
# -L pin cannot reach the board. Sets $NX_TMUX_TMPDIR.
#
# THE SOCKET ROOT IS NOT DERIVED FROM <workdir>, AND NOT FROM $TMPDIR
# (your-org/nexus-code#1481, W2-25). It used to be `<workdir>/tt`, and every
# caller builds <workdir> with `mktemp -d -t` — i.e. under $TMPDIR. The moment
# run-tests.sh gave each suite a PRIVATE TMPDIR (the #1423 harness-leak fix,
# `…/slow-band-logs/watcher__test-x.sh.tmp/nexus-…`), every tmux fixture's
# socket path grew past the 108-byte sun_path limit and all six CI bands went
# red at once — while the runner's comment said "TMUX_TMPDIR is untouched",
# which was true of the variable and false of the behaviour. Two file families
# have opposite constraints: ledgers, ports files and fixture trees may live
# anywhere (a private, reaped TMPDIR is right for them); a tmux socket MUST be
# short. So the root here is `${TMUX_TMPDIR:-/tmp}` when THAT fits — the
# runner pins a short per-suite one, and a worker's is `/tmp/c71780`, the
# sockets-only directory — else `tmux_socket_short_tmpdir`'s `/tmp/tmux-th-…`.
# <workdir> is kept in the signature for its callers and is no longer part of
# the path. The length probe below stays as the BACKSTOP: a path that does not
# fit is refused with its measured length, never handed to tmux to fail
# `File name too long` and be read as a defect in the code under test (#991).
nx_tmux_fixture_init() {
    local work="$1" root
    root="${TMUX_TMPDIR:-/tmp}"
    # Would <root>/tt-<pid>/tmux-<uid>/<40-byte name> fit? If not, the ambient
    # TMUX_TMPDIR is itself too long (a scratchpad path) — fall back to the
    # short pin rather than inherit the defect.
    local probe_root="$root/tt-$$/tmux-$(id -u)/nexus-test-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
    if (( ${#probe_root} > 100 )); then
        if declare -F tmux_socket_short_tmpdir >/dev/null 2>&1; then
            root="$(tmux_socket_short_tmpdir "$$")"
        else
            root="/tmp/tmux-th-$(id -u)-$$"
        fi
    fi
    NX_TMUX_TMPDIR="$root/tt-$$"
    mkdir -p "$NX_TMUX_TMPDIR" || return 1
    export TMUX_TMPDIR="$NX_TMUX_TMPDIR"
    unset TMUX
    # The socket dir now lives OUTSIDE <workdir>, so the caller's `rm -rf $WORK`
    # no longer reaps it. Chain its removal onto the EXIT trap where the shared
    # helper offers a chainer (never clobber the suite's own trap); a run under
    # run-tests.sh is reaped by the runner's per-suite TMUX_TMPDIR regardless.
    if declare -F th_trap_exit >/dev/null 2>&1; then
        th_trap_exit "rm -rf $(printf '%q' "$NX_TMUX_TMPDIR") 2>/dev/null || true"
    fi
    # Fail LOUD rather than emit false FAILs later: a socket path that cannot
    # fit is not a test result, it is an unusable fixture.
    local probe="$NX_TMUX_TMPDIR/tmux-$(id -u)/nexus-test-XXXXX-XX"
    if (( ${#probe} > 100 )); then
        printf 'nx_tmux_fixture_init: socket path is %d bytes (%s) — too close to the 108-byte sun_path limit; TMUX_TMPDIR must be a SHORT root (your-org/nexus-code#991, #1481)\n' \
            "${#probe}" "$probe" >&2
        return 1
    fi
    return 0
}

# nx_write_tmux_shim <dir> <real-tmux-bin> <socket> [extra-args...] — BELT.
# Write a `tmux` shim
# into <dir> that pins <socket>, scrubs $TMUX, and carries the private
# TMUX_TMPDIR. <real-tmux-bin> MUST be a real binary (nx_real_tmux_bin), never
# `command -v tmux`: naming a wrapper here is precisely what re-arms the defect
# this file documents, and it also risks the #1037 shim<->wrapper ping-pong.
nx_write_tmux_shim() {
    local dir="$1" real="$2" sock="$3"
    shift 3 || true
    # Extra args (e.g. `-f <conf>`, the #555 hermetic fixture config) go between
    # the socket pin and the caller's argv, exactly where a hand-rolled shim puts
    # them. They exist so a fixture needing them does not have to hand-roll —
    # hand-rolling is what re-introduces the wrapper capture.
    local extra="" a
    for a in "$@"; do extra="$extra $(printf '%q' "$a")"; done
    mkdir -p "$dir" || return 1
    # Refuse to write a shim that names a wrapper — the whole defect in one
    # line, so it can never be reintroduced silently.
    #
    # `head -c 2`, not `read -r -N 2`: `read -N` does not exist in zsh, so the
    # `|| magic=""` arm made THIS REFUSAL FAIL OPEN under zsh — measured, the
    # same call that exits 1 "refusing … is a SCRIPT (a wrapper)" under bash
    # exits 0 under zsh and WRITES A SHIM NAMING THE WRAPPER. That is an
    # independent defect from the loop in `nx_real_tmux_bin`: repairing the
    # loop does not touch it, and it is the one whose failure mode is a
    # board-reaching shim rather than a skip (your-org/nexus-code#1319).
    local magic
    magic=$(head -c 2 -- "$real" 2>/dev/null) || magic='#!'
    if [ "$magic" = '#!' ]; then
        printf 'nx_write_tmux_shim: refusing — %q is a SCRIPT (a wrapper), not the real tmux binary. Use nx_real_tmux_bin (your-org/nexus-code#1105).\n' \
            "$real" >&2
        return 1
    fi
    cat > "$dir/tmux" <<SHIM
#!/usr/bin/env bash
exec env -u TMUX TMUX_TMPDIR="${TMUX_TMPDIR:-/tmp}" "$real" -L "$sock"$extra "\$@"
SHIM
    chmod +x "$dir/tmux" || return 1
    return 0
}

# nx_tmux_pin_socket <shimdir> — ALARM (raw form). Print the socket path a bare
# `tmux` would reach FROM INSIDE A NEW `bash -c` with <shimdir> on the front of
# $PATH — i.e. exactly the shape a suite uses to drive extracted code, and
# exactly the shape in which the pin has been observed to be displaced.
#
# It must be a NEW bash, not a subshell: the displacement is caused by $BASH_ENV
# being sourced at the start of a non-interactive shell, so a subshell (which
# does not re-source it) would report a pin that the real call sites do not get.
nx_tmux_pin_socket() {
    local shimdir="$1"
    PATH="$shimdir:$PATH" bash -c 'tmux display-message -p "#{socket_path}" 2>&1' 2>/dev/null
}

# nx_assert_tmux_pinned <shimdir> <expected-socket-path> — ALARM. rc 0 if a
# child `bash -c` really does reach <expected-socket-path>; rc 1 otherwise,
# with a diagnostic naming what it reached instead.
#
# Call this ONCE per suite, after the shim is installed and before any leg that
# drives code under test. A suite that skips it is back to trusting a PATH race.
nx_assert_tmux_pinned() {
    local shimdir="$1" want="$2" got
    got=$(nx_tmux_pin_socket "$shimdir")
    case "$got" in
        "$want"|*"$want"*) return 0 ;;
    esac
    printf 'nx_assert_tmux_pinned: the code under test would reach %q, NOT the fixture socket %q.\n' \
        "$got" "$want" >&2
    printf '  A PATH force-front has displaced the fixture shim. Anything this suite drives would\n' >&2
    printf '  operate on that server. See your-org/nexus-code#1105 and this file'"'"'s header.\n' >&2
    return 1
}
