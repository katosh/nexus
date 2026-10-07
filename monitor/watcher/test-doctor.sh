#!/usr/bin/env bash
# test-doctor.sh — `ng doctor` (monitor/doctor.sh), your-org/nexus-code#1722.
#
# Every check is driven both ways against a fixture nexus (never the real
# tree): a healthy setup is all PASS at rc 0, and each planted gap turns
# exactly its own row (cc older / no install, gh below floor / absent, config
# placeholders, config mode, a separate transcript root). A probe that cannot
# run is UNKNOWN, never PASS. --quiet prints only non-PASS rows. The doctor
# writes nothing (the fixture tree is byte-identical before and after).
#
# Run: bash monitor/watcher/test-doctor.sh

set -uo pipefail
if [[ -z "${_DOCTOR_TEST_REEXEC:-}" ]]; then
    export _DOCTOR_TEST_REEXEC=1
    exec env -u NEXUS_ROOT -u NEXUS_STATE_DIR -u CLAUDE_CONFIG_DIR -u NEXUS_GH_MIN_VERSION \
        bash "${BASH_SOURCE[0]}" "$@"
fi
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOC="$(cd "$_dir/.." && pwd)/doctor.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

R="$WORK/nexus"
mkdir -p "$R/config" "$R/monitor/.state" "$R/node_modules/@anthropic-ai/claude-code" "$WORK/home/.claude/projects"
printf '{\n  "dependencies": {\n    "@anthropic-ai/claude-code": "2.1.289"\n  }\n}\n' > "$R/package.json"
set_installed() { printf '{\n  "name": "@anthropic-ai/claude-code",\n  "version": "%s"\n}\n' "$1" \
    > "$R/node_modules/@anthropic-ai/claude-code/package.json"; }
set_installed 2.1.289
cat > "$R/config/load.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --validate ]] && exit "${LOAD_VALIDATE_RC:-0}"
exit 0
EOF
chmod +x "$R/config/load.sh"
printf 'nexus: {}\n' > "$R/config/nexus.yml"; chmod 600 "$R/config/nexus.yml"

# gh clients by version; PATH = one stub dir + a PRIVATE system dir holding
# no gh. `/usr/bin:/bin` is NOT that: a GitHub runner ships /usr/bin/gh, so
# the below-floor and no-gh cases found a capable client and read PASS. This
# host has no system gh, so they passed here and failed only in CI. SYS links
# every tool from the system dirs EXCEPT gh. A capable gh is PLANTED among the
# source dirs on every host, so this fixture is CI-shaped everywhere: if the
# exclusion ever breaks, it goes red locally, not only in CI.
mkgh() { mkdir -p "$WORK/gh-$1"; printf '#!/usr/bin/env bash\necho "gh version %s (2026-01-01)"\n' "$1" > "$WORK/gh-$1/gh"; chmod +x "$WORK/gh-$1/gh"; }
mkgh 2.89.0; mkgh 1.13.0; mkdir -p "$WORK/gh-none"
mkdir -p "$WORK/planted-sys" "$WORK/sysbin"
cp "$WORK/gh-2.89.0/gh" "$WORK/planted-sys/gh"
for _d in /usr/bin /bin "$WORK/planted-sys"; do
    for _t in "$_d"/*; do
        _n=${_t##*/}
        [[ "$_n" == gh || -e "$WORK/sysbin/$_n" || ! -x "$_t" ]] && continue
        ln -s "$_t" "$WORK/sysbin/$_n"
    done
done
SYS="$WORK/sysbin"
assert_eq "FIXTURE the private system dir holds no gh (a planted capable gh was excluded)" \
    "$(PATH="$SYS" command -v gh || echo none)" "none"

run() {   # <gh-dir> [env...] -- runs the doctor, sets OUT and RC
    local ghd="$1"; shift
    OUT=$(env HOME="$WORK/home" NEXUS_ROOT="$R" PATH="$WORK/$ghd:$SYS" "$@" bash "$DOC" 2>&1); RC=$?
}
rowv() { printf '%s\n' "$OUT" | awk -v c="$1" '$2 == c && !seen { print $1; seen = 1 }'; }

snap() { (cd "$R" && find . -printf '%p %s %T@\n' | sort); }
before=$(snap)

echo '=== healthy fixture: every row PASS, rc 0 ==='
run gh-2.89.0
assert_eq "rc 0" "$RC" "0"
for c in cc gh config config-mode transcripts; do assert_eq "$c PASS" "$(rowv "$c")" "PASS"; done
assert_eq "no state written: the fixture tree is unchanged" "$(snap)" "$before"

echo '=== each gap turns its own row ==='
set_installed 2.1.173; run gh-2.89.0
assert_eq "cc older than expected ⇒ WARN" "$(rowv cc)" "WARN"; assert_eq "…rc 0 (WARN is not FAIL)" "$RC" "0"
assert_contains "…names both versions" "$OUT" "2.1.173 is OLDER than expected 2.1.289"
rm -f "$R/node_modules/@anthropic-ai/claude-code/package.json"; run gh-2.89.0
assert_eq "no install ⇒ FAIL" "$(rowv cc)" "FAIL"; assert_eq "…rc 1" "$RC" "1"
set_installed 2.1.289
run gh-1.13.0
assert_eq "gh below the floor ⇒ FAIL" "$(rowv gh)" "FAIL"; assert_eq "…rc 1" "$RC" "1"
run gh-none
assert_eq "no gh at all ⇒ FAIL" "$(rowv gh)" "FAIL"
run gh-2.89.0 LOAD_VALIDATE_RC=4
assert_eq "config placeholders (validate rc 4) ⇒ FAIL" "$(rowv config)" "FAIL"; assert_eq "…rc 1" "$RC" "1"
run gh-2.89.0 LOAD_VALIDATE_RC=3
assert_eq "an inconclusive validate ⇒ UNKNOWN, never PASS" "$(rowv config)" "UNKNOWN"; assert_eq "…and not a FAIL (rc 0)" "$RC" "0"
chmod 644 "$R/config/nexus.yml"; run gh-2.89.0
assert_eq "config readable by group/other ⇒ WARN" "$(rowv config-mode)" "WARN"
chmod 600 "$R/config/nexus.yml"
mkdir -p "$WORK/cfgdir/projects"; run gh-2.89.0 CLAUDE_CONFIG_DIR="$WORK/cfgdir"
assert_eq "a REAL \$CLAUDE_CONFIG_DIR/projects separate from ~/.claude/projects ⇒ WARN" "$(rowv transcripts)" "WARN"
rm -rf "$WORK/cfgdir/projects"; ln -s "$WORK/home/.claude/projects" "$WORK/cfgdir/projects"; run gh-2.89.0 CLAUDE_CONFIG_DIR="$WORK/cfgdir"
assert_eq "…a symlink to it ⇒ PASS" "$(rowv transcripts)" "PASS"
mv "$R/package.json" "$R/package.json.away"; run gh-2.89.0
assert_eq "no expected cc version (no pin, no floor) ⇒ UNKNOWN, never PASS" "$(rowv cc)" "UNKNOWN"
mv "$R/package.json.away" "$R/package.json"

echo '=== --quiet: only the non-PASS rows ==='
set_installed 2.1.173
OUT=$(env HOME="$WORK/home" NEXUS_ROOT="$R" PATH="$WORK/gh-2.89.0:$SYS" bash "$DOC" --quiet 2>&1); RC=$?
assert_contains "--quiet keeps the WARN row" "$OUT" "WARN    cc"
assert_not_contains "--quiet drops the PASS rows" "$OUT" "PASS"
OUT=$(bash "$DOC" --bogus 2>&1); RC=$?
assert_eq "an unknown argument ⇒ rc 2" "$RC" "2"

# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, count=exact): a
# dropped or added assertion is a FAIL, never a quieter green.
#   fixture 1 | healthy 1+5+1 | gaps 3+2+2+1+2+2+1+1+1+1 | --quiet 2, unknown arg 1
EXPECTED=$(( 1 + 7 + 16 + 3 ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
