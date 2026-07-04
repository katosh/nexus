#!/usr/bin/env bash
# Tests for the move-aside-before-install pattern (your-org/nexus-code
# #310, #312): monitor/_trash.sh + its wiring into
# monitor/install-claude-local.sh.
#
# WHY (#312): on NFS a file a running process holds open cannot be
# unlinked — `unlink(2)` silly-renames it to `.nfs<hex>` and the caller
# gets EBUSY, so `npm` swapping an in-use binary aborts and can leave the
# tree binary-less. `rename(2)` DOES succeed on a held-open inode, so the
# standing pattern (#310) is: move the prior install into a gitignored
# trash dir (a rename) before installing fresh.
#
# What this proves:
#   PART A — _trash.sh unit behavior
#     - trash_path moves an existing target aside and frees the path
#     - trash_path on a HELD-OPEN file STILL succeeds (the load-bearing
#       rename-not-unlink property) and the holder is undisturbed
#     - trash_path on a missing target is a silent idempotent no-op
#     - repeated trashing of the same name never collides
#     - clear_trash purges, and --older-than keeps fresh entries
#     - cross-filesystem target falls back to a same-fs `.nexus-trash`
#       (skipped if no second filesystem is available)
#   PART B — install-claude-local.sh wiring
#     - a HELD-OPEN prior install is trashed aside, the reinstall then
#       SUCCEEDS, and .bin/claude is never left dangling
#     - the swap never depends on unlinking the held inode (the npm stub
#       fails EBUSY if the old pkg dir is still in place; success proves
#       it was renamed away first)
#     - a clean tree (no prior install) still installs fine
#     - if the reinstall fails anyway, the trashed prior binary is
#       RESTORED (THE INVARIANT: never leave the tree binary-less)
#
# Fully hermetic: node + npm are PATH-shadow stubs; no network, no real
# Claude Code package.
#
# Run: bash monitor/watcher/test-trash-install.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
TRASH_SRC="$_repo_root/monitor/_trash.sh"
INSTALLER_SRC="$_repo_root/monitor/install-claude-local.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$TRASH_SRC" ]]     || { echo "missing: $TRASH_SRC" >&2; exit 1; }
[[ -f "$INSTALLER_SRC" ]] || { echo "missing: $INSTALLER_SRC" >&2; exit 1; }

WORK=$(mktemp -d)
# Track every holder PID we spawn so teardown never leaks a background
# process — and we NEVER pkill -f (the pattern would match this very
# script's argv). Kill by recorded PID only.
HOLDERS=()
cleanup() {
    local pid
    for pid in "${HOLDERS[@]:-}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# Hold a file open in a background process. Sets HOLDER_PID (NOT via
# command substitution: a backgrounded child started inside $(...) keeps
# the substitution's stdout pipe open and would block until it exits).
# stdout/stderr redirected so the holder never holds any caller pipe.
HOLDER_PID=""
hold_open() {  # $1 = file
    { exec 9<"$1"; sleep 60; } >/dev/null 2>&1 &
    HOLDER_PID=$!
    HOLDERS+=("$HOLDER_PID")
    # Drop it from the job table so bash doesn't print an async
    # "Terminated" notice when teardown kills it (keeps test output clean).
    disown "$HOLDER_PID" 2>/dev/null || true
}

# ====================================================================
echo "=== PART A: _trash.sh unit behavior ==="
# ====================================================================

# (A1) Move an existing file aside: original path freed, dest echoed,
# content preserved.
A=$WORK/a; mkdir -p "$A"
echo payload > "$A/file"
dest=$(NEXUS_TRASH_DIR="$A/.trash" bash "$TRASH_SRC" trash "$A/file"); rc=$?
if (( rc == 0 )) && [[ ! -e "$A/file" ]] && [[ -f "$dest" ]] \
   && [[ "$(cat "$dest")" == payload ]]; then
    ok "trash_path moves an existing file aside (path freed, content kept)"
else
    bad "trash existing" "rc=$rc dest=$dest origin_gone=$([[ -e $A/file ]] && echo no || echo yes)"
fi

# (A2) HELD-OPEN file: rename must still succeed and not disturb the
# holder (the property that makes this safe where unlink is not).
B=$WORK/b; mkdir -p "$B"
echo held > "$B/binary"
hold_open "$B/binary"; holder=$HOLDER_PID
dest=$(NEXUS_TRASH_DIR="$B/.trash" bash "$TRASH_SRC" trash "$B/binary"); rc=$?
if (( rc == 0 )) && [[ ! -e "$B/binary" ]] && [[ -f "$dest" ]] \
   && kill -0 "$holder" 2>/dev/null; then
    ok "trash_path succeeds on a HELD-OPEN file; holder undisturbed"
else
    bad "trash held-open" "rc=$rc origin_gone=$([[ -e $B/binary ]] && echo no || echo yes) holder_alive=$(kill -0 "$holder" 2>/dev/null && echo yes || echo no)"
fi

# (A3) Missing target → silent idempotent no-op (rc 0, no stdout).
out=$(NEXUS_TRASH_DIR="$WORK/none/.trash" bash "$TRASH_SRC" trash "$WORK/none/missing"); rc=$?
if (( rc == 0 )) && [[ -z "$out" ]]; then
    ok "trash_path on a missing target → idempotent no-op (rc 0, no output)"
else
    bad "trash missing no-op" "rc=$rc out='$out'"
fi

# (A4) Repeated trashing of the same basename never collides.
C=$WORK/c; mkdir -p "$C"
echo one > "$C/dup"; d1=$(NEXUS_TRASH_DIR="$C/.trash" bash "$TRASH_SRC" trash "$C/dup")
echo two > "$C/dup"; d2=$(NEXUS_TRASH_DIR="$C/.trash" bash "$TRASH_SRC" trash "$C/dup")
n=$(find "$C/.trash" -maxdepth 1 -name 'dup-*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$d1" != "$d2" ]] && (( n == 2 )); then
    ok "repeated trashing of same name → distinct entries (no collision)"
else
    bad "trash uniqueness" "d1=$d1 d2=$d2 count=$n"
fi

# (A5) clear_trash purges; --older-than keeps fresh entries.
E=$WORK/e/.trash; mkdir -p "$E"
echo x > "$E/old-entry"; echo y > "$E/new-entry"
# Backdate one entry 10 days so --older-than 5 reaps it but keeps the fresh one.
touch -d '10 days ago' "$E/old-entry" 2>/dev/null || touch -t 202001010000 "$E/old-entry"
bash "$TRASH_SRC" --clear --older-than 5 --root "$E" >/dev/null 2>&1
if [[ ! -e "$E/old-entry" ]] && [[ -e "$E/new-entry" ]]; then
    ok "clear_trash --older-than reaps old, keeps fresh"
else
    bad "clear older-than" "old_gone=$([[ -e $E/old-entry ]] && echo no || echo yes) new_kept=$([[ -e $E/new-entry ]] && echo yes || echo no)"
fi
# Full clear removes the rest.
bash "$TRASH_SRC" --clear --root "$E" >/dev/null 2>&1
if [[ ! -e "$E/new-entry" ]]; then
    ok "clear_trash (no age filter) purges everything"
else
    bad "clear all" "new-entry still present"
fi

# (A6) Cross-filesystem fallback to a same-fs `.nexus-trash`. Only runs
# if we can find a second filesystem; otherwise skipped (still counted).
second_fs=""
for cand in /dev/shm /run/user/"$(id -u)"; do
    [[ -d "$cand" && -w "$cand" ]] || continue
    if [[ "$(stat -c '%d' "$cand" 2>/dev/null)" != "$(stat -c '%d' "$WORK" 2>/dev/null)" ]]; then
        second_fs="$cand"; break
    fi
done
if [[ -n "$second_fs" ]]; then
    F=$(mktemp -d -p "$second_fs" trash-xfs.XXXXXX)
    echo z > "$F/target"
    # Point the trash root at a DIFFERENT fs ($WORK) than the target ($F).
    dest=$(NEXUS_TRASH_DIR="$WORK/xfs-trash" bash "$TRASH_SRC" trash "$F/target")
    if [[ "$dest" == "$F/.nexus-trash/"* ]] && [[ -f "$dest" ]] && [[ ! -e "$F/target" ]]; then
        ok "cross-fs target → same-fs .nexus-trash fallback (rename stays local)"
    else
        bad "cross-fs fallback" "dest=$dest (expected under $F/.nexus-trash/)"
    fi
    rm -rf "$F" 2>/dev/null || true
else
    ok "cross-fs fallback (skipped: no second filesystem available)"
fi

# ====================================================================
echo
echo "=== PART B: install-claude-local.sh wiring ==="
# ====================================================================

PIN="9.9.9"

# Build a fake nexus tree with the REAL installer + its sourced siblings,
# and a PATH-shadow node/npm. The npm stub here is held-open-aware: it
# fails EBUSY if the old @anthropic-ai/claude-code dir is STILL present
# when it runs (i.e. it was NOT trashed aside first), and installs fresh
# otherwise — directly tying install success to the rename-aside step.
new_fixture() {
    NEXUS="$WORK/nexus.$RANDOM$RANDOM"
    STUB_BIN="$NEXUS/.stubbin"
    NPM_LOG="$NEXUS/.npm-argv.log"
    NPM_FLAGS="$NEXUS/.npm-flags"
    mkdir -p "$NEXUS/monitor" "$STUB_BIN" "$NPM_FLAGS"

    cp "$INSTALLER_SRC" "$NEXUS/monitor/install-claude-local.sh"
    chmod +x "$NEXUS/monitor/install-claude-local.sh"
    cp "$(dirname "$INSTALLER_SRC")/_cc-version.sh" "$NEXUS/monitor/_cc-version.sh"
    cp "$(dirname "$INSTALLER_SRC")/_trash.sh" "$NEXUS/monitor/_trash.sh"

    cat > "$NEXUS/package.json" <<EOF
{ "dependencies": { "@anthropic-ai/claude-code": "$PIN" } }
EOF

    cat > "$STUB_BIN/node" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --version) echo "v20.11.0" ;; *) exit 0 ;; esac
EOF
    chmod +x "$STUB_BIN/node"

    # npm stub. Modes via NPM_STUB_MODE:
    #   swap-needs-rename : EBUSY if the old pkg dir is still present
    #                       (unlink-of-held-open), else install fresh.
    #   always-fail       : never produces a binary (drives restore path).
    cat > "$STUB_BIN/npm" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then echo "11.0.0"; exit 0; fi
printf '%s\n' "\$*" >> "$NPM_LOG"

pkgdir="\$PWD/node_modules/@anthropic-ai/claude-code"

make_binary() {
    mkdir -p "\$PWD/node_modules/.bin" "\$pkgdir"
    cat > "\$pkgdir/cli.js" <<INNER
#!/usr/bin/env bash
echo "$PIN (Claude Code)"
INNER
    chmod +x "\$pkgdir/cli.js"
    # npm-faithful relative symlink into the package dir.
    ln -sf ../@anthropic-ai/claude-code/cli.js "\$PWD/node_modules/.bin/claude"
}

case "\${NPM_STUB_MODE:-swap-needs-rename}" in
    swap-needs-rename)
        if [[ -e "\$pkgdir" ]]; then
            # Old install still in place → simulate the held-open unlink EBUSY.
            touch "$NPM_FLAGS/saw-pkg-present"
            echo "npm error code EBUSY" >&2
            echo "npm error EBUSY: resource busy or locked, unlink '\$pkgdir/cli.js'" >&2
            exit 1
        fi
        touch "$NPM_FLAGS/saw-pkg-absent"
        make_binary; exit 0 ;;
    always-fail)
        echo "npm error generic failure" >&2; exit 1 ;;
    partial-then-fail)
        # Mid-extract failure: leaves a PARTIAL pkg dir at the destination
        # (no working cli.js), then fails. Restore must aside the partial
        # before moving the known-good prior copy back.
        mkdir -p "\$pkgdir"; echo partial > "\$pkgdir/.partial"
        echo "npm error mid-extract failure" >&2; exit 1 ;;
    *) echo "unknown NPM_STUB_MODE" >&2; exit 99 ;;
esac
EOF
    chmod +x "$STUB_BIN/npm"
}

run_installer() {  # extra env=val ... pass through
    env PATH="$STUB_BIN:$PATH" "$@" \
        bash "$NEXUS/monitor/install-claude-local.sh"
}

seed_prior_install() {  # $1 = version reported by the prior binary
    # Faithful npm layout: executable in the package dir, .bin/claude a
    # RELATIVE symlink into it (../@anthropic-ai/...). The relative symlink
    # is what makes the restore-on-failure path a real test — moved into the
    # trash dir it dangles, so an `-e`-only restore guard would skip it.
    mkdir -p "$NEXUS/node_modules/.bin" "$NEXUS/node_modules/@anthropic-ai/claude-code"
    cat > "$NEXUS/node_modules/@anthropic-ai/claude-code/cli.js" <<EOF
#!/usr/bin/env bash
echo "$1 (Claude Code)"
EOF
    chmod +x "$NEXUS/node_modules/@anthropic-ai/claude-code/cli.js"
    ln -sf ../@anthropic-ai/claude-code/cli.js "$NEXUS/node_modules/.bin/claude"
}

binary_version() {
    [[ -x "$NEXUS/node_modules/.bin/claude" ]] || { echo "<none>"; return; }
    "$NEXUS/node_modules/.bin/claude" --version 2>/dev/null | awk '{print $1}'
}

trash_entries() {  # count entries in the fixture trash dir
    find "$NEXUS/monitor/.state/.trash" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

# (B1) HELD-OPEN prior install (stale version) → trashed aside, reinstall
# SUCCEEDS, new binary present & correct, never dangling. The held-open fd
# proves the rename works on a busy inode.
new_fixture
seed_prior_install "8.0.0"          # stale → forces a real reinstall
hold_open "$NEXUS/node_modules/@anthropic-ai/claude-code/cli.js"; holder=$HOLDER_PID
out=$(run_installer NPM_STUB_MODE=swap-needs-rename 2>&1); rc=$?
if (( rc == 0 )) && [[ "$(binary_version)" == "$PIN" ]] \
   && [[ -x "$NEXUS/node_modules/.bin/claude" ]] \
   && kill -0 "$holder" 2>/dev/null; then
    ok "held-open prior install → trashed aside, reinstall succeeds, binary present"
else
    bad "held-open swap" "rc=$rc binary=$(binary_version) holder_alive=$(kill -0 "$holder" 2>/dev/null && echo yes || echo no) out=$out"
fi

# (B2) The swap did NOT depend on unlinking the held inode: the npm stub
# saw the pkg dir ABSENT on its run (it was renamed away first), and a
# trash entry exists for the prior install.
if [[ -e "$NEXUS/.npm-flags/saw-pkg-absent" ]] \
   && [[ ! -e "$NEXUS/.npm-flags/saw-pkg-present" ]] \
   && (( $(trash_entries) >= 1 )); then
    ok "old pkg dir renamed away BEFORE npm ran (no held-inode unlink); prior install in trash"
else
    bad "rename-before-install" "saw_absent=$([[ -e $NEXUS/.npm-flags/saw-pkg-absent ]] && echo yes || echo no) saw_present=$([[ -e $NEXUS/.npm-flags/saw-pkg-present ]] && echo yes || echo no) trash=$(trash_entries)"
fi

# (B3) Clean tree (no prior install) still installs fine with the same
# stub — the trash-aside is a no-op and must not break the fresh path.
new_fixture
out=$(run_installer NPM_STUB_MODE=swap-needs-rename 2>&1); rc=$?
if (( rc == 0 )) && [[ "$(binary_version)" == "$PIN" ]] && (( $(trash_entries) == 0 )); then
    ok "clean tree → fresh install succeeds, nothing trashed"
else
    bad "clean install" "rc=$rc binary=$(binary_version) trash=$(trash_entries) out=$out"
fi

# (B4) THE INVARIANT under the new path: if the reinstall fails anyway,
# the trashed prior binary is RESTORED — tree never left binary-less.
new_fixture
seed_prior_install "8.0.0"
out=$(run_installer NPM_STUB_MODE=always-fail 2>&1); rc=$?
# binary_version executes .bin/claude, so 8.0.0 proves the restored bin
# RESOLVES (a dangling-symlink restore would read <none>).
if (( rc != 0 )) && [[ "$(binary_version)" == "8.0.0" ]]; then
    ok "reinstall fails after trash-aside → prior binary restored & resolves (invariant held)"
else
    bad "restore-on-failure" "rc=$rc binary=$(binary_version) out=$out"
fi

# (B5) Compounding case (skeptic req-001 F2): the reinstall fails MID-EXTRACT
# leaving a PARTIAL pkg dir at the destination. Restore must aside the
# partial and move BOTH known-good prior copies back — not strand them.
new_fixture
seed_prior_install "8.0.0"
out=$(run_installer NPM_STUB_MODE=partial-then-fail 2>&1); rc=$?
if (( rc != 0 )) && [[ "$(binary_version)" == "8.0.0" ]] \
   && [[ ! -e "$NEXUS/node_modules/@anthropic-ai/claude-code/.partial" ]]; then
    ok "mid-extract partial pkg → partial asided, prior install fully restored"
else
    bad "restore over partial" "rc=$rc binary=$(binary_version) partial=$([[ -e $NEXUS/node_modules/@anthropic-ai/claude-code/.partial ]] && echo present || echo gone) out=$out"
fi

echo
echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then echo "FAIL"; exit 1; fi
echo "ALL TESTS PASSED"
exit 0
