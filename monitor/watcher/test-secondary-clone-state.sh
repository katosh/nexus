#!/usr/bin/env bash
# Tests for the SECONDARY-CLONE STATE FORK (your-org/nexus-code#577).
#
# THE BUG. `spawn-worker.sh` resolved `NEXUS_ROOT` unconditionally from its own
# location, so invoking it from a secondary clone silently re-rooted the ENTIRE
# nexus state into that clone — and invoking it from a secondary clone is a
# PRESCRIBED workflow (CLAUDE.md requires watcher-touching work to run in its own
# clone under `work/`). Confirmed forensics from the incident: the clone at
# `work/nexus-code-570fix/` held the only record of the skeptic's spawn
# (`<clone>/monitor/.state/action-log.jsonl`), the require-gate marker
# (`<clone>/monitor/.state/skeptic/pending/<worker>`), and the verdict report
# (`<clone>/reports/`), while the marker actually BLOCKING retirement sat in the
# PRIMARY state dir, where nothing could ever clear it. `retire-preflight`
# therefore reported `safe=0 … required skeptic has not returned a verdict` for a
# window whose verdict existed — permanently, leaving only a hand-`rm` of the very
# marker that exists to prevent hand-clearing.
#
# WHAT IS UNDER TEST, in the three places the fork showed up:
#   1. spawn-worker.sh resolves the PRIMARY root: an inherited valid NEXUS_ROOT
#      wins; failing that, a script tree nested under an outer nexus's `work/` is
#      recognised STRUCTURALLY as a secondary clone and re-rooted;
#      NEXUS_ALLOW_SECONDARY_ROOT=1 opts out. WORKDIR is never changed.
#   2. `ng report-init` pins reports to the corpus (`<primary>/reports`) from
#      both resolution paths — NEXUS_ROOT pointing INTO a clone, and NEXUS_ROOT
#      unset with cwd inside a clone.
#   3. `skeptic-channel resolve` is the sanctioned, audited replacement for the
#      hand-`rm` the bug forced: orchestrator-only, mandatory rationale, refuses
#      when there is no marker.
#
# Hermetic: fake primary + secondary clone in a tmpdir, stub tmux/claude, no
# network, no tmux windows created.
#
# Run: bash monitor/watcher/test-secondary-clone-state.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MON="$_test_dir/.."
SPAWN_REAL="$MON/spawn-worker.sh"
NG_REAL="$MON/ng"
SKCH_REAL="$MON/skeptic-channel.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() {
    local label="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] && ok "$label" || bad "$label" "got $(printf %q "$got") want $(printf %q "$want")"
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay" && ok "$label" || bad "$label" "missing $(printf %q "$needle")"
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    grep -qF -- "$needle" <<<"$hay" && bad "$label" "unexpectedly found $(printf %q "$needle")" || ok "$label"
}

WORK=$(mktemp -d -t nexus-577-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
SPAWN_TMP="$WORK/tmp"; mkdir -p "$SPAWN_TMP"
export TMPDIR="$SPAWN_TMP"

STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<'STUB'
#!/bin/bash
case "$1" in new-window) echo '@7'; exit 0 ;; *) exit 0 ;; esac
STUB
chmod +x "$STUB_BIN/tmux"

# --- build a nexus tree at $1 (primary or clone) --------------------------
make_nexus() {
    local root="$1"
    mkdir -p "$root/monitor" "$root/config" "$root/reports" \
             "$root/skills/nexus.worker-defaults" "$root/node_modules/.bin"
    cp "$SPAWN_REAL"            "$root/monitor/spawn-worker.sh"
    # spawn-worker.sh REFUSES (78) without the shim guard template it emits
    # into every launcher (your-org/nexus-code#589). Without this line the
    # fixture fails for a reason that has nothing to do with #577 re-rooting.
    cp "$MON/guard-block.sh.in" "$root/monitor/guard-block.sh.in"
    cp "$NG_REAL"               "$root/monitor/ng"
    cp "$SKCH_REAL"             "$root/monitor/skeptic-channel.sh"
    cp "$MON/_claude-bin.sh"    "$root/monitor/_claude-bin.sh"
    cp "$MON/_tmux-window.sh"   "$root/monitor/_tmux-window.sh"
    cp "$MON/_fm_lib.sh"        "$root/monitor/_fm_lib.sh"
    # `ng` sources this and REFUSES TO START without it
    # (your-org/nexus-code#601/#605: degrading to the silent-coercion
    # behaviour it replaces is worse than refusing).
    cp "$MON/_bookkeeping.sh"   "$root/monitor/_bookkeeping.sh"
    # your-org/nexus-code#1077: `ng` also refuses without the primary-root resolver.
    cp "$MON/_nexus-root.sh"   "$root/monitor/_nexus-root.sh"
    chmod +x "$root/monitor/spawn-worker.sh" "$root/monitor/ng" \
             "$root/monitor/skeptic-channel.sh"
    printf '#!/bin/bash\necho "stub-claude: $*"\n' > "$root/node_modules/.bin/claude"
    chmod +x "$root/node_modules/.bin/claude"
    printf '#!/usr/bin/env bash\nprintf fake-token\n' > "$root/monitor/mint-token.sh"
    chmod +x "$root/monitor/mint-token.sh"
    cat > "$root/monitor/worker-settings.json" <<'EOF'
{ "hooks": {} }
EOF
    cat > "$root/skills/nexus.worker-defaults/SKILL.md" <<'EOF'
---
description: stub
---

# nexus.worker-defaults

## Worker floor

- Floor body stub.
EOF
    # config/load.sh stub. Deliberately does NOT answer `nexus.root`: that
    # mirrors a clone with no config/nexus.yml of its own, which is exactly the
    # state in which the real config falls through to the example template's
    # `/path/to/nexus` placeholder. The fix must not depend on it.
    cat > "$root/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)       printf 'default-org/default-repo' ;;
    github.user_login) printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$root/config/load.sh"
}

PRIMARY="$WORK/nexus"
make_nexus "$PRIMARY"
CLONE="$PRIMARY/work/nexus-code-mytask"
make_nexus "$CLONE"

printf 'do the thing\n' > "$WORK/prompt.txt"

# Render a launcher via the clone's spawn-worker.sh and print the NEXUS_ROOT it
# exports (the stub tmux never runs it, so the tempfile survives for inspection).
launcher_root() {   # launcher_root <name> [env VAR=val ...]
    local name="$1"; shift
    ( cd "$CLONE" && env "$@" PATH="$STUB_BIN:$PATH" \
        "$CLONE/monitor/spawn-worker.sh" -n "$name" -c "$CLONE" -p "$WORK/prompt.txt" \
        >/dev/null 2>"$WORK/spawn.err" ) || true
    local body
    body=$(cat "$SPAWN_TMP/spawn-launcher-$name".*.sh 2>/dev/null)
    rm -f "$SPAWN_TMP/spawn-launcher-$name".*.sh
    sed -n 's/^export NEXUS_ROOT="\(.*\)"$/\1/p' <<<"$body" | head -1
}

echo '=== 1. spawn-worker.sh resolves the PRIMARY root, not its own tree ==='

# 1a. THE INCIDENT SHAPE: the orchestrator's env carries NEXUS_ROOT=<primary>
#     and it runs the CLONE's launcher. Pre-fix this exported the clone.
got=$(launcher_root incident NEXUS_ROOT="$PRIMARY")
assert_eq "inherited primary NEXUS_ROOT wins over the script's own tree" "$got" "$PRIMARY"
assert_contains "and says so, loudly" "$(cat "$WORK/spawn.err")" \
    "spawning against the inherited (primary) root"

# 1b. No inherited root at all → recognise the clone STRUCTURALLY (nested under
#     an outer nexus's work/) and re-root. This is the path that needs no env
#     and no config, so it holds for an operator shell too.
got=$(launcher_root structural NEXUS_ROOT=)
assert_eq "a secondary clone under <primary>/work is detected structurally" "$got" "$PRIMARY"
assert_contains "structural detection is announced" "$(cat "$WORK/spawn.err")" \
    "SECONDARY CLONE"

# 1c. Explicit opt-out keeps the old behaviour, for a deliberate nested nexus.
got=$(launcher_root optout NEXUS_ROOT= NEXUS_ALLOW_SECONDARY_ROOT=1)
assert_eq "NEXUS_ALLOW_SECONDARY_ROOT=1 keeps the script-relative root" "$got" "$CLONE"

# 1d. NEGATIVE CONTROL: a standalone nexus that is NOT nested under another
#     nexus's work/ must resolve to ITSELF. Without this, the fix could be
#     "always walk up", which would break every fork and the primary itself.
STANDALONE="$WORK/other-nexus"
make_nexus "$STANDALONE"
got=$( ( cd "$STANDALONE" && env NEXUS_ROOT= PATH="$STUB_BIN:$PATH" \
          "$STANDALONE/monitor/spawn-worker.sh" -n standalone -c "$STANDALONE" \
          -p "$WORK/prompt.txt" >/dev/null 2>&1 ) || true
       body=$(cat "$SPAWN_TMP/spawn-launcher-standalone".*.sh 2>/dev/null)
       rm -f "$SPAWN_TMP/spawn-launcher-standalone".*.sh
       sed -n 's/^export NEXUS_ROOT="\(.*\)"$/\1/p' <<<"$body" | head -1 )
assert_eq "a standalone nexus resolves to itself (not re-rooted)" "$got" "$STANDALONE"

# 1e. A worker in the primary's OWN work/<project> (a plain project checkout,
#     not a nexus clone) must still get the primary — and the launcher must not
#     touch WORKDIR. Guards the "state goes to primary, code/cwd stay put" split.
mkdir -p "$PRIMARY/work/plainproj"
( cd "$PRIMARY" && env NEXUS_ROOT="$PRIMARY" PATH="$STUB_BIN:$PATH" \
    "$PRIMARY/monitor/spawn-worker.sh" -n plainw -c "$PRIMARY/work/plainproj" \
    -p "$WORK/prompt.txt" >/dev/null 2>&1 ) || true
body=$(cat "$SPAWN_TMP/spawn-launcher-plainw".*.sh 2>/dev/null)
rm -f "$SPAWN_TMP/spawn-launcher-plainw".*.sh
assert_contains "primary launcher exports the primary root" "$body" \
    "export NEXUS_ROOT=\"$PRIMARY\""
assert_contains "WORKDIR is untouched by root resolution" "$body" \
    "cd \"$PRIMARY/work/plainproj\""

# 1f. The #577/#589 INTERACTION (found by the depth-1 skeptic on PR #598).
#     Re-rooting moves the #589 guard's PRESENCE, not just state: a clone
#     carrying the guard, re-rooted onto a primary that predates it, used to
#     find neither name under $NEXUS_ROOT/monitor and run NO check — fail-open,
#     in exactly the mixed-checkout state a partially-pulled nexus is in. The
#     launcher must therefore also look in the tree it was generated FROM.
#
#     UPGRADED by your-org/nexus-code#612. The "say so LOUDLY" half used to be
#     a WARNING that let the spawn proceed, which is the same fail-open shape
#     one notch quieter: an operator who does not read a launcher's stderr gets
#     an ungated agent either way. The emitted block now REFUSES (78) when
#     neither tree carries a guard, and the search itself moved into the single
#     source monitor/guard-block.sh.in — so the second root is named
#     NEXUS_SPAWN_CODE_ROOT rather than being interpolated as a literal path.
#     The assertions below follow the mechanism to where it lives; the property
#     under test — a re-rooted clone still gets a real check, or no spawn at
#     all — is the same one, and is now stronger.
( cd "$CLONE" && env NEXUS_ROOT="$PRIMARY" PATH="$STUB_BIN:$PATH" \
    "$CLONE/monitor/spawn-worker.sh" -n gatefallback -c "$CLONE" \
    -p "$WORK/prompt.txt" >/dev/null 2>&1 ) || true
gbody=$(cat "$SPAWN_TMP/spawn-launcher-gatefallback".*.sh 2>/dev/null)
rm -f "$SPAWN_TMP/spawn-launcher-gatefallback".*.sh
assert_contains "gate lookup falls back to the generating tree (#589 stays armed)" \
    "$gbody" "export NEXUS_SPAWN_CODE_ROOT=\"$CLONE\""
assert_contains "gate lookup still prefers the resolved (primary) root first" \
    "$gbody" "for _nx_root in \"\$NEXUS_ROOT\" \"\$NEXUS_SPAWN_CODE_ROOT\""
assert_contains "an ungated spawn is REFUSED, not merely announced (#612)" \
    "$gbody" "REFUSING TO SPAWN — no shim precondition guard found"
# The code root must be the CLONE the launcher was generated from, never the
# re-rooted primary — otherwise the fallback searches the same tree twice and
# the #577 mixed-checkout case is unguarded while looking guarded.
assert_not_contains "…and the second root is not silently the primary again" \
    "$gbody" "export NEXUS_SPAWN_CODE_ROOT=\"$PRIMARY\""

echo
echo '=== 2. ng report-init pins reports to the CORPUS ==='

# 2a. NEXUS_ROOT pointing INTO the clone — the exact state a pre-fix
#     clone-spawned worker inherited. The report must land in the PRIMARY corpus.
out=$( cd "$CLONE" && NEXUS_WORKER_WINDOW="" NEXUS_ROOT="$CLONE" \
        "$CLONE/monitor/ng" report-init verdict 2>/dev/null )
assert_contains "NEXUS_ROOT=<clone> still writes into the primary corpus" \
    "$out" "$PRIMARY/reports/"
assert_not_contains "…and NOT into the clone's own reports/" "$out" "$CLONE/reports/"

# 2b. NEXUS_ROOT unset, cwd inside the clone → the cwd walk-up used to find the
#     clone's own reports/. It must de-nest to the corpus too.
out=$( cd "$CLONE" && env -u NEXUS_ROOT NEXUS_WORKER_WINDOW="" \
        "$CLONE/monitor/ng" report-init verdict2 2>/dev/null )
assert_contains "NEXUS_ROOT unset + cwd in clone → primary corpus" \
    "$out" "$PRIMARY/reports/"
assert_not_contains "…not the clone's reports/ (walk-up de-nested)" "$out" "$CLONE/reports/"

# 2c. NEGATIVE CONTROL: from the PRIMARY the answer must be unchanged — the
#     de-nesting must not fire where there is nothing to de-nest.
out=$( cd "$PRIMARY" && NEXUS_WORKER_WINDOW="" NEXUS_ROOT="$PRIMARY" \
        "$PRIMARY/monitor/ng" report-init plain 2>/dev/null )
assert_contains "from the primary, the corpus is unchanged" "$out" "$PRIMARY/reports/"

# 2d. An explicit --reports-dir outside the corpus is a deliberate choice: it is
#     honoured, but it WARNS naming the corpus.
err=$( cd "$PRIMARY" && NEXUS_WORKER_WINDOW="" NEXUS_ROOT="$PRIMARY" \
        "$PRIMARY/monitor/ng" report-init elsewhere \
        --reports-dir "$WORK/elsewhere" 2>&1 >/dev/null )
assert_contains "explicit out-of-corpus --reports-dir warns" "$err" \
    "OUTSIDE the reports corpus"
assert_contains "the warning names the corpus so the fix is copy-paste" "$err" \
    "$PRIMARY/reports"

echo
echo '=== 3. skeptic-channel resolve: the sanctioned clear ==='

SK_STATE="$PRIMARY/monitor/.state"
mkdir -p "$SK_STATE/skeptic/pending"
MARKER="$SK_STATE/skeptic/pending/stuckwin"
REASON='verdict returned by stuckwin-skeptic and lives at reports/stuckwin-skeptic_verdict.md; marker never cleared because the skeptic ran from a secondary clone'

# 3a. A worker may NOT clear its own required validation.
out=$( NEXUS_ROOT="$PRIMARY" NEXUS_WORKER_WINDOW=stuckwin \
        "$PRIMARY/monitor/skeptic-channel.sh" resolve stuckwin --reason "$REASON" 2>&1 ); rc=$?
assert_eq "worker-invoked resolve is refused (exit 1)" "$rc" "1"
assert_contains "refusal explains the authority boundary" "$out" "OPERATOR/ORCHESTRATOR override"

# 3b. A rationale is mandatory and must be substantive — the entire failure mode
#     was an UNAUDITED clear, so a keystroke must not satisfy it.
echo 1 > "$MARKER"
out=$( NEXUS_ROOT="$PRIMARY" env -u NEXUS_WORKER_WINDOW \
        "$PRIMARY/monitor/skeptic-channel.sh" resolve stuckwin --reason "ok" 2>&1 ); rc=$?
assert_eq "a token rationale is rejected" "$rc" "1"
assert_contains "…and says why a substantive one is required" "$out" "substantive explanation"
[[ -f "$MARKER" ]] && ok "rejected resolve left the marker in place" \
    || bad "rejected resolve" "the marker was removed anyway"

# 3c. The happy path: marker gone, rationale recorded beside it.
out=$( NEXUS_ROOT="$PRIMARY" env -u NEXUS_WORKER_WINDOW \
        "$PRIMARY/monitor/skeptic-channel.sh" resolve stuckwin --reason "$REASON" 2>&1 ); rc=$?
assert_eq "orchestrator resolve succeeds" "$rc" "0"
[[ ! -e "$MARKER" ]] && ok "the marker is cleared" || bad "resolve" "marker still present"
RAT="$SK_STATE/skeptic/pending/.stuckwin.cleared-rationale"
if [[ -s "$RAT" ]]; then
    ok "a rationale file is written beside the marker"
    assert_contains "the rationale records the operator's reason verbatim" "$(cat "$RAT")" \
        "marker never cleared because the skeptic ran from a secondary clone"
    assert_contains "the rationale cites the class issue" "$(cat "$RAT")" "#577"
else
    bad "rationale" "no rationale file at $RAT"
fi

# 3d. Refuse when there is NO marker: a silent success would let `resolve`
#     decay into a reflex incantation run before every retire.
out=$( NEXUS_ROOT="$PRIMARY" env -u NEXUS_WORKER_WINDOW \
        "$PRIMARY/monitor/skeptic-channel.sh" resolve nosuchwin --reason "$REASON" 2>&1 ); rc=$?
assert_eq "resolve with no marker is refused, not a silent no-op" "$rc" "1"
assert_contains "…and says there was nothing to resolve" "$out" "nothing to resolve"

# 3e. It is reachable through the `ng` front door the operator actually types.
out=$( NEXUS_ROOT="$PRIMARY" env -u NEXUS_WORKER_WINDOW \
        "$PRIMARY/monitor/ng" skeptic resolve nosuchwin2 --reason "$REASON" 2>&1 ); rc=$?
assert_eq 'ng skeptic resolve reaches the verb' "$rc" "1"
assert_contains "…via the same code path" "$out" "nothing to resolve"

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%d)\n' "$PASS"; exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2; exit 1
fi
