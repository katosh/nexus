#!/usr/bin/env bash
# Repo-wide lint: every flock'd `exec {fd}>` / `exec N>` lock acquisition
# under monitor/ must show a hardening pattern (flock-fd class,
# your-org/nexus-code#494).
#
# flock(2) binds to the OPEN FILE DESCRIPTION, and bash never sets
# FD_CLOEXEC on exec-opened fds — so any child spawned while the lock is
# held inherits the fd and keeps the lock alive after the opener exits.
# The class has been paid for twice as individual instances (#451 the
# watcher instance lock; #468/#471 the asset lock, where an inherited
# fd 9 in git-credential-cache--daemon held the upload lock for 2h37m),
# and a third live site sat in bootstrap.sh until #494. This lint closes
# the CLASS: a new acquisition fails here until its author demonstrates
# one of:
#
#   * close-at-spawn — a same-fd `{NAME}>&-` / `N>&-` redirect somewhere
#     in the file (the #451/#471 idiom; bash cannot set FD_CLOEXEC, so
#     denying the fd at each spawn is the only in-shell hardening); or
#   * a `# flock-fd: <reason>` annotation within the 8 lines above the
#     `exec` — the deliberate-hold escape, for locks whose JOB is to
#     span the children (e.g. _install-lib.sh serializing a whole
#     install). The reason is forced prose: the author must say why the
#     hold is safe.
#
# Subshell-scoped acquisitions — `( flock -n 9 || exit; … ) 9>>lock` —
# are out of scope: the fd dies with the subshell, and all three
# incidents were exec-form. So are test files (fixtures legitimately
# model bad behaviour).
#
# Self-proof: the lint runs its scanner against a built-in fixture tree
# containing synthetic bad sites and asserts it CATCHES them — a lint
# verified only against the already-clean tree has proved nothing.
#
# Run: bash monitor/watcher/test-flock-fd-cloexec.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MON_DIR=$(cd "$_test_dir/.." && pwd)

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

WORK=$(mktemp -d -t nexus-flockfd-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# --- the scanner ------------------------------------------------------------
# Prints one "path:line fd=<token>" per UNHARDENED flock'd exec acquisition
# under <root>. Pure grep/sed over source text — a lint, not a parser: it
# can be fooled by pathological quoting, but it catches the idioms this
# repo actually writes, and the fixture below keeps it honest.
scan_tree() {
    local root="$1" f line lineno text fd num tok start
    while IFS= read -r f; do
        case "$f" in
            */test-*|*/_test_helpers.sh|*/test-integration/*) continue ;;
        esac
        grep -q 'flock' "$f" 2>/dev/null || continue
        while IFS= read -r line; do
            lineno="${line%%:*}"; text="${line#*:}"
            # comment lines are not acquisitions
            [[ "$text" =~ ^[[:space:]]*# ]] && continue
            fd=$(sed -nE 's/.*exec[[:space:]]+\{([A-Za-z_][A-Za-z0-9_]*)\}[<>].*/\1/p' <<<"$text")
            num=$(sed -nE 's/.*exec[[:space:]]+([0-9]+)[<>].*/\1/p' <<<"$text")
            tok="${fd:-$num}"
            [[ -n "$tok" ]] || continue
            # only LOCK acquisitions: the same fd token appears on a flock line
            grep -E '(^|[^#])flock' "$f" | grep -q -- "$tok" || continue
            # hardened: a same-fd close-at-spawn anywhere in the file
            if [[ -n "$fd" ]]; then
                grep -qF -- "{$fd}>&-" "$f" && continue
            else
                grep -qE "(^|[^0-9])$num>&-" "$f" && continue
            fi
            # annotated: `# flock-fd:` within the 8 lines above the exec
            start=$(( lineno > 8 ? lineno - 8 : 1 ))
            sed -n "${start},${lineno}p" "$f" | grep -q '# flock-fd:' && continue
            printf '%s:%s fd=%s\n' "$f" "$lineno" "$tok"
        done < <(grep -nE 'exec [0-9]+[<>]|exec \{[A-Za-z_][A-Za-z0-9_]*\}[<>]' "$f" 2>/dev/null)
    done < <(find "$root" -name '*.sh' -type f | LC_ALL=C sort)
}

# --- self-proof: the scanner catches synthetic bad sites --------------------

echo '=== fixture: the scanner catches what it exists to catch ==='
FIX="$WORK/fixture"
mkdir -p "$FIX"

# BAD 1: brace-named fd, flock'd, spawns a child, no close, no annotation.
cat > "$FIX/bad-brace.sh" <<'EOF'
#!/usr/bin/env bash
exec {mylock}>"$1"
flock -n "$mylock" || exit 0
some-long-lived-daemon &
EOF

# BAD 2: numbered fd, flock'd, held across the script, no close/annotation.
cat > "$FIX/bad-numbered.sh" <<'EOF'
#!/usr/bin/env bash
exec 8>>"$1"
flock -n 8 || exit 0
setsid some-service &
EOF

# CLEAN 1: close-at-spawn hardening (#451/#471 idiom).
cat > "$FIX/clean-hardened.sh" <<'EOF'
#!/usr/bin/env bash
exec {lk}>"$1"
flock -n "$lk" || exit 0
some-child {lk}>&- &
EOF

# CLEAN 2: deliberate hold, annotated.
cat > "$FIX/clean-annotated.sh" <<'EOF'
#!/usr/bin/env bash
# flock-fd: the lock's job is to span the children; all foreground.
exec 9>"$1"
flock 9 || exit 0
do-the-work
EOF

# CLEAN 3: exec fd open with no flock anywhere — not a lock.
cat > "$FIX/clean-noflock.sh" <<'EOF'
#!/usr/bin/env bash
exec 3>"$1"
echo hi >&3
EOF

# CLEAN 4: subshell-scoped flock (fd dies with the subshell; out of scope).
cat > "$FIX/clean-subshell.sh" <<'EOF'
#!/usr/bin/env bash
( flock -w 10 200 || exit 9; do-the-work ) 200>>"$1"
EOF

fixture_hits=$(scan_tree "$FIX")
assert_eq "fixture: exactly the two bad sites flagged" "$(wc -l <<<"$fixture_hits" | tr -d ' ')" "2"
assert_eq "fixture: brace-named bad site flagged" \
    "$(grep -c 'bad-brace.sh:2 fd=mylock' <<<"$fixture_hits")" "1"
assert_eq "fixture: numbered bad site flagged" \
    "$(grep -c 'bad-numbered.sh:2 fd=8' <<<"$fixture_hits")" "1"

# --- the real tree -----------------------------------------------------------

echo '=== monitor/: every flock-guarded exec fd is hardened or annotated ==='
real_hits=$(scan_tree "$MON_DIR")
if [[ -z "$real_hits" ]]; then
    printf '  PASS: no unhardened flock-fd acquisition under monitor/\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: unhardened flock-fd acquisition(s) — each inherited fd keeps the lock\n' >&2
    printf '        alive in every child spawned while held (class #494; instances #451,\n' >&2
    printf '        #468/#471, bootstrap.sh). Fix: close at each spawn (`{FD}>&-` — bash\n' >&2
    printf '        cannot set FD_CLOEXEC), or annotate a deliberate hold with\n' >&2
    printf '        `# flock-fd: <why the hold is safe>` just above the exec:\n' >&2
    sed 's/^/          /' <<<"$real_hits" >&2
    FAIL=$(( FAIL + 1 ))
fi

# --- summary -----------------------------------------------------------------

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "FAILED"
exit 1
