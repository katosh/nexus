#!/usr/bin/env bash
# test-agent-tmpdir.sh — every agent shell gets a usable TMPDIR
# (your-org/nexus-code#1628).
#
# Claude Code leaves TMPDIR unset, so `$TMPDIR/x` was `/x` at the sandbox root,
# at rc 0: three stray writes in one session, and `rm -rf $TMPDIR/foo` is
# `rm -rf /foo`. monitor/shellenv/tmpdir.sh now establishes a private per-user
# directory when TMPDIR is unset or empty; bash_env.sh and .zshenv source it in a
# Claude Code TOOL SHELL (parent comm `claude`); the agent LAUNCHERS
# (spawn-worker.sh, _respawn.sh) source it before starting claude.
#
# What is pinned: the value is NON-EMPTY, ABSOLUTE, a WRITABLE directory, mode
# 0700 and owned by us; a TMPDIR that is already set is never touched; a shell
# whose parent is NOT claude is left alone (a suite's deliberate
# `env -u TMPDIR bash …` must keep testing the unset path); a relative base or a
# symlinked parent is REFUSED LOUDLY rather than half-trusted.
#
# HERMETIC, and never at the filesystem root: every base directory is a fixture
# under this suite's own mktemp root, passed as NEXUS_TMPDIR_BASE, and every
# shell runs under `env -i`. Nothing here stats, writes or cleans `/`.
#
# Run: bash monitor/watcher/test-agent-tmpdir.sh

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
SHELLENV="$REPO_ROOT/monitor/shellenv"
. "$_test_dir/_test_helpers.sh"

PASS=0; FAIL=0; SKIP=0
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

WORK=$(mktemp -d -t agent-tmpdir-XXXXXX) || { echo "FAIL: mktemp" >&2; exit 1; }
th_trap_exit 'rm -rf "$WORK"'
mkdir -p "$WORK/home" "$WORK/as-claude" "$WORK/as-launcher"
MYUID=$(id -u)

# Stand-in parents, as in test-resume-env-strip.sh: a script's comm is its
# basename, so a child of `as-claude/claude` reads parent comm `claude`.
for d in as-claude/claude as-launcher/launcher; do
    printf '#!/bin/bash\nexec_child() { "$@"; }\nexec_child "$@"\n' > "$WORK/$d"
    chmod +x "$WORK/$d"
done
c=$("$WORK/as-claude/claude" bash -c 'read -r x < /proc/$PPID/comm; printf %s "$x"')
[[ "$c" == claude ]] && ok "rig: a child of the stand-in reads parent comm 'claude'" \
    || bad "rig: parent comm read '$c' (the rig cannot reach the axis)"

# One probe for both shells: TMPDIR's value, whether it is set, and $? at start.
PROBE='printf "%s|%s|%s" "$?" "${TMPDIR+set}" "${TMPDIR-}"'

# run <parent> <sh> <base> [VAR=val …] — a hermetic shell under <parent>.
run() {
    local parent="$1" sh="$2" base="$3"; shift 3
    env -i HOME="$WORK/home" PATH="/usr/bin:/bin" \
        BASH_ENV="$SHELLENV/bash_env.sh" NEXUS_PREV_BASH_ENV= ZDOTDIR="$SHELLENV" \
        NEXUS_TMPDIR_BASE="$base" "$@" \
        "$parent" "$sh" -c "$PROBE" 2>"$WORK/err"
}

# check_good <label> <result> <base> — the established value is usable.
check_good() {
    local label="$1" r="$2" base="$3" want="$3/claude-$MYUID/tmp" v
    v=${r#*|*|}
    if [[ "$r" == "0|set|$want" ]]; then
        ok "$label: TMPDIR set to the private dir, \$? = 0 at shell start"
    else
        bad "$label: got '$r' (want 0|set|$want)"
    fi
    # The guard the issue asks for: NON-EMPTY, ABSOLUTE, a WRITABLE directory.
    if [[ -n "$v" && "$v" == /* && -d "$v" && -w "$v" ]]; then
        ok "$label: the value is non-empty, absolute and a writable directory"
    else
        bad "$label: '$v' is not a non-empty absolute writable directory"
    fi
    if [[ "$(stat -c '%a %u' "$want" 2>/dev/null)" == "700 $MYUID" ]]; then
        ok "$label: the directory is mode 0700 and owned by us"
    else
        bad "$label: $want is '$(stat -c '%a %u' "$want" 2>&1)' (want '700 $MYUID')"
    fi
    [[ ! -s "$WORK/err" ]] && ok "$label: silent on stderr" || bad "$label: stderr: $(cat "$WORK/err")"
}

for sh in bash zsh; do
    if ! command -v "$sh" >/dev/null 2>&1; then
        printf '  SKIP: no %s on this host; its prelude arm is unmeasured here\n' "$sh"
        _th_skip; _SKIPPED_SHELLS=$(( ${_SKIPPED_SHELLS:-0} + 1 )); continue
    fi
    echo "=== $sh tool shell (parent = claude) ==="
    B="$WORK/base-$sh-unset"; mkdir -p "$B"
    check_good "$sh under claude, TMPDIR UNSET" "$(run "$WORK/as-claude/claude" "$sh" "$B")" "$B"

    B="$WORK/base-$sh-empty"; mkdir -p "$B"
    check_good "$sh under claude, TMPDIR set EMPTY" "$(run "$WORK/as-claude/claude" "$sh" "$B" TMPDIR=)" "$B"

    B="$WORK/base-$sh-set"; mkdir -p "$B" "$WORK/mine-$sh"
    r=$(run "$WORK/as-claude/claude" "$sh" "$B" TMPDIR="$WORK/mine-$sh")
    [[ "$r" == "0|set|$WORK/mine-$sh" && ! -e "$B/claude-$MYUID" ]] \
        && ok "$sh under claude: an already-set TMPDIR is left alone, and nothing is created" \
        || bad "$sh already-set: got '$r', created: $(ls "$B" 2>/dev/null | tr '\n' ' ')"

    echo "=== $sh under a NON-claude parent (a suite's env -u TMPDIR) ==="
    B="$WORK/base-$sh-launcher"; mkdir -p "$B"
    r=$(run "$WORK/as-launcher/launcher" "$sh" "$B")
    [[ "$r" == "0||" && ! -e "$B/claude-$MYUID" ]] \
        && ok "$sh under a launcher: TMPDIR stays UNSET (the unset path stays testable)" \
        || bad "$sh under launcher: got '$r'"
done

echo "=== refusals are LOUD and leave TMPDIR unset ==="
r=$(run "$WORK/as-claude/claude" bash "relative-base")
[[ "$r" == "0||" ]] && grep -qF 'nexus-code#1628' "$WORK/err" \
    && ok "a RELATIVE base is refused: TMPDIR unset, one #1628 line on stderr" \
    || bad "relative base: got '$r', stderr '$(cat "$WORK/err")'"
B="$WORK/base-symlink"; mkdir -p "$B" "$WORK/elsewhere/tmp"
ln -s "$WORK/elsewhere" "$B/claude-$MYUID"
r=$(run "$WORK/as-claude/claude" bash "$B")
[[ "$r" == "0||" ]] && grep -qF 'nexus-code#1628' "$WORK/err" \
    && ok "a SYMLINKED claude-<uid> parent is refused: TMPDIR unset, one #1628 line on stderr" \
    || bad "symlinked parent: got '$r', stderr '$(cat "$WORK/err")'"
# …and NOTHING is created through the link (skeptic on PR #1630: mkdir ran
# before the symlink check, so `<target>/tmp` was created and only then refused).
B="$WORK/base-symlink2"; mkdir -p "$B" "$WORK/elsewhere2"
ln -s "$WORK/elsewhere2" "$B/claude-$MYUID"
r=$(run "$WORK/as-claude/claude" bash "$B")
[[ "$r" == "0||" && ! -e "$WORK/elsewhere2/tmp" ]] \
    && ok "a symlinked claude-<uid> is refused BEFORE mkdir: nothing is created through the link" \
    || bad "symlink mkdir-through: got '$r', created: $(ls "$WORK/elsewhere2" 2>&1 | tr '\n' ' ')"
# A PRE-EXISTING dir must be private: mode exactly 0700 (a 0777 one was accepted).
B="$WORK/base-mode"; mkdir -p "$B/claude-$MYUID/tmp"; chmod 700 "$B/claude-$MYUID"; chmod 777 "$B/claude-$MYUID/tmp"
r=$(run "$WORK/as-claude/claude" bash "$B")
[[ "$r" == "0||" ]] && grep -qF 'nexus-code#1628' "$WORK/err" \
    && ok "a pre-existing 0777 tmp dir is refused: TMPDIR unset, one #1628 line on stderr" \
    || bad "0777 dir: got '$r', stderr '$(cat "$WORK/err")'"

echo "=== the value is EXPORTED to children ==="
B="$WORK/base-child"; mkdir -p "$B"
r=$(env -i HOME="$WORK/home" PATH="/usr/bin:/bin" BASH_ENV="$SHELLENV/bash_env.sh" NEXUS_PREV_BASH_ENV= \
    NEXUS_TMPDIR_BASE="$B" "$WORK/as-claude/claude" bash -c "bash -c '$PROBE'" 2>/dev/null)
[[ "$r" == "0|set|$B/claude-$MYUID/tmp" ]] && ok "a grandchild of claude (a script the tool shell runs) inherits TMPDIR" \
    || bad "grandchild: got '$r'"

echo "=== the LAUNCHERS export it; locals-env.sh does NOT ==="
# locals-env.sh is sourced by services and helpers (labsh-supervised, ng, the
# gh/tmux/pip wrappers), not only by launchers. A first cut set TMPDIR there,
# and a callee with a private TMPDIR under a caller without one broke
# test-jupyter-service.sh's rotation cases (4 rows, reproduced alone twice; the
# same tree with TMPDIR preset, and the tree without the hook, both 111/0).
B="$WORK/base-le"; mkdir -p "$B"
r=$(env -i HOME="$WORK/home" PATH="/usr/bin:/bin" NEXUS_TMPDIR_BASE="$B" \
    bash -c ". '$REPO_ROOT/monitor/locals-env.sh' >/dev/null 2>&1; printf '%s|%s' \"\${TMPDIR+set}\" \"\${TMPDIR-}\"")
[[ "$r" == "|" && ! -e "$B/claude-$MYUID" ]] && ok "locals-env.sh leaves TMPDIR UNSET and creates nothing (services and helpers source it)" \
    || bad "locals-env: got '$r'"
# Every launcher site carries the line: spawn-worker.sh's three launchers and
# the orchestrator respawn launcher. Counted by the construct, then the exact
# line is EXECUTED (unescaped from its heredoc) rather than trusted as text.
_line='[ -z "\${TMPDIR:-}" ] && [ -f "\$NEXUS_ROOT/monitor/shellenv/tmpdir.sh" ] && . "\$NEXUS_ROOT/monitor/shellenv/tmpdir.sh" || true'
n_sw=$(grep -cxF -- "$_line" "$REPO_ROOT/monitor/spawn-worker.sh")
n_rs=$(grep -cxF -- "$_line" "$REPO_ROOT/monitor/watcher/_respawn.sh")
# spawn-worker has FIVE launchers since the Codex harness (#1640/#1642; reviewed
# for #1643 — both Codex launchers carry this line in the same prelude position).
[[ "$n_sw" == 5 && "$n_rs" == 1 ]] && ok "every launcher sources tmpdir.sh (spawn-worker 5, respawn 1)" \
    || bad "launcher sites: spawn-worker $n_sw (want 5), respawn $n_rs (want 1)"
B="$WORK/base-launcher-line"; mkdir -p "$B"
_exec=${_line//\\\$/\$}
r=$(env -i HOME="$WORK/home" PATH="/usr/bin:/bin" NEXUS_ROOT="$REPO_ROOT" NEXUS_TMPDIR_BASE="$B" \
    bash -c "$_exec; printf '%s|%s' \"\${TMPDIR+set}\" \"\${TMPDIR-}\"")
[[ "$r" == "set|$B/claude-$MYUID/tmp" ]] && ok "the launcher line, executed, exports the private TMPDIR" \
    || bad "launcher line: got '$r'"

echo "=== set -eu callers survive the prelude ==="
B="$WORK/base-eu"; mkdir -p "$B"
r=$(env -i HOME="$WORK/home" PATH="/usr/bin:/bin" BASH_ENV="$SHELLENV/bash_env.sh" NEXUS_PREV_BASH_ENV= \
    NEXUS_TMPDIR_BASE="$B" "$WORK/as-claude/claude" bash -euc 'printf "alive|%s" "$TMPDIR"' 2>&1)
[[ "$r" == "alive|$B/claude-$MYUID/tmp" ]] && ok "bash -eu under claude: the SET path does not abort the shell" \
    || bad "set -eu: got '$r'"

# 1 rig + per shell (4 x 2 good-path groups of 4 = 8, + 2 controls = 10) x 2
# shells + 4 refusals + 1 grandchild + 3 launcher/locals-env + 1 set -eu = 30.
EXPECTED=$(( 30 - 10 * ${_SKIPPED_SHELLS:-0} ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
