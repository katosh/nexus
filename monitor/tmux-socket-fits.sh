#!/usr/bin/env bash
# tmux-socket-fits.sh — will `tmux -L <name>` be able to bind its socket?
# (your-org/nexus-code#991)
#
#   monitor/tmux-socket-fits.sh [--socket NAME] [--tmpdir DIR] [--quiet]
#   monitor/tmux-socket-fits.sh --suggest [--tag TAG]
#
# THE THREE OUTCOMES THIS EXISTS TO SEPARATE. Before it, a `TMUX_TMPDIR` too
# long for `sun_path` presented as a FAIL of the code under test — outcome (2)
# masquerading as outcome (3) — which cost five misattributed reds and one
# retracted finding in a single session:
#
#   (1) the path FITS                          -> exit 0, verdict `fits`
#   (2) the path DOES NOT FIT                  -> exit 3, verdict `too-long`,
#       a REFUSAL naming the measured length, the 107-byte usable maximum, the
#       composed path, and the remedy
#   (3) a genuine failure of the thing tested  -> not this tool's business; it
#       never runs tmux, so it can never be confused for one
#
# Exit codes: 0 fits · 2 usage · 3 REFUSED (too long).
#
# `--suggest` prints a private `TMUX_TMPDIR` that cannot blow the ceiling, for
# pasting into an `export` — the remedy, not just the diagnosis.
set -uo pipefail
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_here/_tmux_socket.sh"

sock=default; dir_set=0; dir=""; quiet=0; suggest=0; tag=$$
while [ $# -gt 0 ]; do
    case "$1" in
        --socket|-L) sock="${2:?--socket needs a value}"; shift 2 ;;
        --tmpdir)    dir="${2:?--tmpdir needs a value}"; dir_set=1; shift 2 ;;
        --tag)       tag="${2:?--tag needs a value}"; shift 2 ;;
        --quiet|-q)  quiet=1; shift ;;
        --suggest)   suggest=1; shift ;;
        # Explicit, not a line-numbered slice of the header above — that stops
        # being the help text as soon as the header is edited.
        -h|--help)   cat <<'USAGE'; exit 0 ;;
tmux-socket-fits.sh — will `tmux -L <name>` be able to bind its socket?
(your-org/nexus-code#991)

  tmux-socket-fits.sh [--socket NAME] [--tmpdir DIR] [--quiet]
  tmux-socket-fits.sh --suggest [--tag TAG]

  --socket NAME   the -L socket name (default: default)
  --tmpdir DIR    check DIR instead of the ambient $TMUX_TMPDIR
  --suggest       print a TMUX_TMPDIR that cannot blow the ceiling
  --quiet         suppress the success line

EXIT CODES
  0  the path FITS
  3  REFUSED — too long, naming the measured length, the composed path and a remedy
  2  usage

tmux composes ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<socket-name>, and 107 bytes is
the longest path a NUL-terminating caller can bind (sun_path is 108; at 108 the
kernel still binds with a full-struct addrlen, but nothing here does that). A
session scratchpad TMUX_TMPDIR is over the limit before the suffix, and every
real-tmux suite then reports the failure as a defect in the code under test.
USAGE
        *) printf 'tmux-socket-fits.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [ "$suggest" -eq 1 ]; then
    tmux_socket_short_tmpdir "$tag"; printf '\n'; exit 0
fi

if [ "$dir_set" -eq 1 ]; then
    verdict=$(tmux_socket_verdict "$sock" "$dir"); rc=$?
    shown_dir="$dir"
else
    verdict=$(tmux_socket_verdict "$sock"); rc=$?
    shown_dir="${TMUX_TMPDIR:-<unset> (tmux falls back to /tmp)}"
fi
# Split on the FIRST TWO spaces only. `set -- $verdict` would word-split the
# path as well, and a TMUX_TMPDIR containing a space is exactly the value a
# reader would hand this tool while debugging a path problem.
measured="${verdict#* }"; measured="${measured%% *}"
# `sockpath`, NOT `path`: in zsh `path` is a tied array bound to $PATH and
# assigning to it destroys PATH silently at rc 0 (your-org/nexus-code#945).
# This file is bash, where the tie does not exist — but the blast radius if it
# were ever sourced from zsh is `monitor/ghwrap` falling off the front of PATH,
# which is `#497`, and the habit costs nothing to keep.
sockpath="${verdict#* }"; sockpath="${sockpath#* }"

if [ "$rc" -eq 0 ]; then
    [ "$quiet" -eq 1 ] || printf 'tmux-socket: fits — %s bytes  %s\n' "${measured%%/*}" "$sockpath"
    exit 0
fi

# The refusal. Everything a reader needs is ON THIS SCREEN, because the whole
# cost of #991 was that the number had to be re-derived by someone who had
# already concluded the code was broken.
printf 'tmux-socket: REFUSED — socket path is %s bytes; the usable maximum is %s.\n' \
       "${measured%%/*}" "$TMUX_SUN_PATH_MAX" >&2
printf '  composed path : %s\n' "$sockpath" >&2
printf '  TMUX_TMPDIR   : %s\n' "$shown_dir" >&2
printf '  why           : sun_path is 108 bytes, and 107 is the longest path a\n' >&2
printf '                  NUL-terminating caller (tmux, python, anything C-string)\n' >&2
printf '                  can bind. tmux composes\n' >&2
printf '                  ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<socket-name>, and a\n' >&2
printf '                  session-scratchpad TMUX_TMPDIR is over the limit on its own.\n' >&2
printf '  this is NOT   : a failure of the code under test. tmux was never asked to\n' >&2
printf '                  do anything; the address could not be formed.\n' >&2
printf '  remedy        : export TMUX_TMPDIR=%s && mkdir -p "$TMUX_TMPDIR"\n' \
       "$(tmux_socket_short_tmpdir "$tag")" >&2
exit 3
