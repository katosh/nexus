#!/usr/bin/env bash
# toolchain-bash.sh — build and cache a pinned GNU bash so this workspace can
# FALSIFY a claim about a bash version it does not ship.
#
# THE BLIND SPOT (your-org/nexus-code#610). No host in this workspace runs
# bash 5.x; CI runs only 5.2. Local verification therefore cannot reproduce a
# 5.2-only defect even in principle, and CI cannot reproduce a 4.4-only one.
# Two 5.2-only traps have already been paid for in full:
#
#   * run-tests.sh's fork-floor probe. `( ulimit -Su N; /bin/true )` does not
#     reliably fork — bash may exec the last simple command of a subshell in
#     place of the subshell, and 5.2 does so where 4.4 does not. RLIMIT_NPROC
#     was never exercised, every candidate "succeeded", the binary search
#     collapsed to its lower bound, and CI capped forks at 87 against a real
#     floor of 566. Every test then died of EAGAIN. Fixed in #597.
#   * `patsub_replacement`, on by default in 5.2, silently corrupted generated
#     `gh` stubs and made ng-tests fail "got 1 want 0" on 5.2+ only.
#
# Both were found painfully, in CI, after the fact. This script is what makes
# the local environment able to find the next one first.
#
# COST, MEASURED NOT ASSUMED. The #597 skeptic built 5.2 from source on this
# host in minutes; this script is that procedure, pinned and cached. What does
# NOT work, so nobody re-treads it: `ml Singularity` (3.5.3) cannot pull modern
# images (`unsupported schema version 2` on docker://debian:12).
#
# USAGE
#   monitor/toolchain-bash.sh                      # build/ensure the default (5.2)
#   monitor/toolchain-bash.sh --version 4.4.18     # the other side of the gap
#   monitor/toolchain-bash.sh --print-path         # just print it (build if absent)
#   monitor/toolchain-bash.sh --check              # exit 0 iff already built
#
#   # run any suite under it:
#   NEXUS_TEST_SHELL=$(monitor/toolchain-bash.sh --print-path) \
#       monitor/watcher/run-tests.sh monitor/test-*.sh
#
# INTEGRITY. Each version pins the upstream sha256 and the build REFUSES on a
# mismatch. This is trust-on-first-use against ftp.gnu.org rather than an
# OpenPGP verification against the GNU keyring — it pins the artifact from this
# point forward, which is what reproducibility needs, but it is not by itself
# proof of provenance. Stated here rather than implied.

set -uo pipefail

_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_here/.." && pwd)

DEFAULT_VERSION=5.2
TOOLCHAIN_DIR="${NEXUS_TOOLCHAIN_DIR:-$REPO_ROOT/monitor/.state/toolchain}"

# version → upstream sha256 of bash-<version>.tar.gz on ftp.gnu.org.
sha_for() {
    case "$1" in
        5.2)    echo a139c166df7ff4471c5e0733051642ee5556c1cc8a4a78f145583c5c81ab32fb ;;
        4.4.18) echo 604d9eec5e4ed5fd2180ee44dd756ddca92e0b6aa4217bbab2b6227380317f23 ;;
        *)      echo "" ;;
    esac
}

die() { printf 'toolchain-bash: %s\n' "$*" >&2; exit 1; }
say() { [[ -n "${QUIET:-}" ]] || printf 'toolchain-bash: %s\n' "$*" >&2; }

VERSION="$DEFAULT_VERSION"
PRINT_PATH=0
CHECK_ONLY=0
FORCE=0
QUIET=""
while (( $# )); do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --print-path) PRINT_PATH=1; QUIET=1; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        --force) FORCE=1; shift ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

WANT_SHA=$(sha_for "$VERSION")
[[ -n "$WANT_SHA" ]] || die "no pinned sha256 for bash-$VERSION.
Add one to sha_for() after verifying it against ftp.gnu.org. Refusing to
build an unpinned tarball — an unpinned toolchain is not a reproducible one."

PREFIX="$TOOLCHAIN_DIR/bash-$VERSION"
BIN="$PREFIX/bin/bash"

# ---- already built? --------------------------------------------------------
# Verify by ASKING THE BINARY, not by testing for the file. A truncated or
# half-installed build leaves the path present and the interpreter broken,
# which would hand every caller a toolchain that silently is not the version
# it claims to be.
built_ok() {
    [[ -x "$BIN" ]] || return 1
    local got
    got=$("$BIN" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null) || return 1
    [[ "$VERSION" == "$got" || "$VERSION" == "$got".* ]]
}

if (( CHECK_ONLY )); then
    built_ok && { (( PRINT_PATH )) && echo "$BIN"; exit 0; }
    exit 1
fi

if (( ! FORCE )) && built_ok; then
    say "bash-$VERSION already built at $BIN"
    (( PRINT_PATH )) && echo "$BIN"
    exit 0
fi

# ---- prerequisites, checked up front and named individually ----------------
missing=()
for tool in curl tar make cc sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
# `cc` may be absent while gcc is present.
if [[ " ${missing[*]} " == *" cc "* ]] && command -v gcc >/dev/null 2>&1; then
    missing=("${missing[@]/cc}")
fi
missing=($(printf '%s\n' "${missing[@]:-}" | grep -v '^$' || true))
if (( ${#missing[@]} > 0 )); then
    die "missing build prerequisites: ${missing[*]}
On the cluster, \`module load\` a toolchain first. This script will not
silently fall back to the system bash — a caller that asked for $VERSION and
got 4.4 would draw exactly the false conclusion #610 is about."
fi

WORK=$(mktemp -d) || die "mktemp failed"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

TARBALL="bash-$VERSION.tar.gz"
URL="https://ftp.gnu.org/gnu/bash/$TARBALL"

say "fetching $URL"
curl -fsSL --max-time 600 "$URL" -o "$WORK/$TARBALL" \
    || die "download failed: $URL (no network? the sandbox reaches ftp.gnu.org)"

got_sha=$(sha256sum "$WORK/$TARBALL" | awk '{print $1}')
if [[ "$got_sha" != "$WANT_SHA" ]]; then
    die "sha256 MISMATCH for $TARBALL
  expected $WANT_SHA
  got      $got_sha
Refusing to build. Either the mirror served something else or the pin is
stale; resolve it deliberately rather than by relaxing this check."
fi
say "sha256 ok ($got_sha)"

say "building (this takes a few minutes; output at $WORK/build.log)"
(
    set -e
    cd "$WORK"
    tar xzf "$TARBALL"
    cd "bash-$VERSION"
    # --without-bash-malloc: bash's bundled allocator does not build cleanly on
    # every modern glibc/toolchain pairing, and we want the system allocator's
    # behaviour anyway — the target here is bash's SHELL semantics, not its
    # memory allocator.
    ./configure --prefix="$PREFIX" --without-bash-malloc
    make -j"$(nproc 2>/dev/null || echo 2)"
    make install
) >"$WORK/build.log" 2>&1 || {
    tail -n 40 "$WORK/build.log" >&2
    die "build failed — last 40 log lines above (full log was $WORK/build.log)"
}

built_ok || die "build completed but $BIN does not report version $VERSION"

say "built $("$BIN" --version | head -1)"
say "path: $BIN"
(( PRINT_PATH )) && echo "$BIN"
exit 0
