#!/usr/bin/env bash
# test-codex-run.sh — monitor/codex-run.sh, the supervised Codex co-worker
# (your-org/nexus-code#1640, layer 1), against a STUB `codex`.
#
# What a stub can and cannot certify. The stub speaks the `codex exec --json`
# event vocabulary as MEASURED from codex-cli 0.156.1 (thread.started,
# turn.started, item.completed{command_execution}, turn.completed,
# turn.failed, error) and records what codex-run hands it — argv, stdin, the
# key's presence. So this suite certifies codex-run's OWN logic: argument
# handling, the verdict taxonomy, the exact-diff snapshot, and the two leak
# properties (prompt and key never in argv). It cannot certify that the real
# binary still emits that vocabulary; monitor/codex-harness/test-codex-run-real.sh
# runs the REAL binary against the mock Responses backend for that half.
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Population (skeptic F5, #1640): the helper and its resolver library, so an
# edit to either selects this suite in `ng guards-for-diff`.
# shellcheck disable=SC1091
. "$_self_dir/../_guard_population.sh"
gp_population() { printf '%s\n' monitor/codex-run.sh monitor/_codex.sh; }
gp_handle "$@"
# shellcheck source=_test_helpers.sh
. "$_self_dir/_test_helpers.sh"

RUN="$_self_dir/../codex-run.sh"
[[ -x "$RUN" ]] || th_abort "codex-run.sh not executable at $RUN"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/codexrun.XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ---- fake nexus root: no codex-cli install, no config -----------------------
# NEXUS_ROOT points here so the version floor (9.9.9) and the local pin are
# the suite's, never the operator's. The binary always comes from CODEX_BIN
# (the stub, or a path that does not exist for the "unavailable" case), so an
# installed codex on PATH can never be reached by this suite.
FAKE_ROOT="$WORK/root"; mkdir -p "$FAKE_ROOT/codex-cli"
printf '{ "dependencies": { "@openai/codex": "9.9.9" } }\n' > "$FAKE_ROOT/codex-cli/package.json"

STUB="$WORK/bin/codex"; mkdir -p "$WORK/bin"; LOG="$WORK/stublog"; mkdir -p "$LOG"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Stub codex. Mode from $STUB_MODE; records argv/stdin/env into $STUB_LOG.
if [[ "${1:-}" == "--version" ]]; then echo "codex-cli ${STUB_VERSION:-9.9.9}"; exit 0; fi
printf '%s\n' "$@" > "$STUB_LOG/argv"
cat > "$STUB_LOG/stdin"
if [[ -n "${CODEX_API_KEY:-}" ]]; then printf '%s' "$CODEX_API_KEY" > "$STUB_LOG/key"; else : > "$STUB_LOG/key"; fi
cdir=""; prev=""
for a in "$@"; do [[ "$prev" == "-C" ]] && cdir="$a"; prev="$a"; done
tid="01stub00-0000-7000-8000-000000000001"
echo '{"type":"thread.started","thread_id":"'"$tid"'"}'
echo '{"type":"turn.started"}'
case "${STUB_MODE:-ok}" in
  ok)
    [[ -n "$cdir" ]] && echo "from codex" > "$cdir/codex-made.txt"
    echo '{"type":"item.completed","item":{"id":"i0","type":"command_execution","command":"echo","exit_code":0,"status":"completed"}}'
    echo '{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"did it"}}'
    echo '{"type":"turn.completed","usage":{}}' ;;
  wide)
    # skeptic F3: a tracked-tree write, a GITIGNORED write, and a write
    # OUTSIDE --cd — only the first can appear in diff.patch.
    [[ -n "$cdir" ]] && { echo "from codex" > "$cdir/codex-made.txt"; mkdir -p "$cdir/build"; echo x > "$cdir/build/cache"; }
    [[ -n "${STUB_OUTSIDE:-}" ]] && echo y > "$STUB_OUTSIDE/outside.txt"
    echo '{"type":"item.completed","item":{"id":"i0","type":"command_execution","command":"make build","exit_code":0,"status":"completed"}}'
    echo '{"type":"turn.completed","usage":{}}' ;;
  ok-rc1)
    echo '{"type":"turn.completed","usage":{}}'; exit 1 ;;
  failed)
    echo '{"type":"error","message":"Quota exceeded. Check your plan and billing details."}'
    echo '{"type":"turn.failed","error":{"message":"Quota exceeded. Check your plan and billing details."}}'
    exit 1 ;;
  no-terminal)
    exit 0 ;;
  hang)
    sleep 60 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB"

REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q . || th_abort "git init"
th_require_fixture_repo "$REPO" "codex-run fixture repo"
echo base > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m base || th_abort "fixture commit"

echo "fix the thing — PROMPT-SENTINEL-7Q" > "$WORK/task.txt"

# _run <out-subdir> [codex-run args…] ; sets RC OUT. Hermetic env: the stub
# is found via CODEX_BIN; no real key reaches it; CODEX_HOME is empty.
_run() {
    local o="$WORK/out-$1"; shift
    RC=0
    OUT=$(env -u OPENAI_API_KEY -u CODEX_API_KEY \
              NEXUS_ROOT="$FAKE_ROOT" NEXUS_STATE_DIR="$WORK/state" \
              CODEX_HOME="$WORK/codexhome" CODEX_BIN="${T_BIN-$STUB}" STUB_LOG="$LOG" \
              STUB_MODE="${T_MODE:-ok}" STUB_VERSION="${T_VER:-9.9.9}" STUB_OUTSIDE="$WORK/outside" \
              ${T_KEY:+OPENAI_API_KEY="$T_KEY"} \
              bash "$RUN" --cd "${T_CD:-$REPO}" --prompt-file "$WORK/task.txt" --out "$o" \
                   --timeout "${T_TIMEOUT:-60}" "$@" < "${T_STDIN:-/dev/null}" 2>"$o.stderr") || RC=$?
    OUT_DIR="$o"
}
T_KEY="sk-test-NOT-A-REAL-KEY-4242"

echo "=== 1. usage ==="
RC=0; bash "$RUN" --prompt-file "$WORK/task.txt" >/dev/null 2>&1 || RC=$?
assert_rc "no --cd -> usage rc 2" "$RC" "2"
RC=0; bash "$RUN" --cd "$REPO" >/dev/null 2>&1 || RC=$?
assert_rc "no task -> usage rc 2" "$RC" "2"
RC=0; bash "$RUN" --cd "$REPO" --prompt-file "$WORK/task.txt" --timeout 0 >/dev/null 2>&1 || RC=$?
assert_rc "--timeout 0 -> usage rc 2" "$RC" "2"
RC=0; bash "$RUN" --cd "$REPO" --prompt-file "$WORK/task.txt" --bogus >/dev/null 2>&1 || RC=$?
assert_rc "unknown flag -> usage rc 2" "$RC" "2"

echo "=== 2. completed: exact diff, caller index untouched, leak properties ==="
_run ok
assert_rc       "turn.completed -> rc 0" "$RC" "0"
assert_contains "verdict line says completed" "$OUT" "codex-run: verdict=completed exit=0"
assert_contains "diff.patch holds codex's new file" "$(cat "$OUT_DIR/diff.patch" 2>/dev/null)" "+from codex"
assert_eq       "files_changed is exactly 1" "$(awk -F= '$1=="files_changed"{print $2}' "$OUT_DIR/status")" "1"
assert_eq       "caller's index untouched (nothing staged)" "$(git -C "$REPO" diff --cached --name-only)" ""
assert_eq       "thread id recorded" "$(awk -F= '$1=="thread_id"{print $2}' "$OUT_DIR/status")" "01stub00-0000-7000-8000-000000000001"
assert_eq       "prompt delivered on STDIN, byte-exact" "$(cat "$LOG/stdin")" "$(cat "$WORK/task.txt")"
assert_not_contains "prompt NOT in codex argv (#1612)" "$(cat "$LOG/argv")" "PROMPT-SENTINEL-7Q"
assert_eq       "OPENAI_API_KEY mapped to CODEX_API_KEY for exec" "$(cat "$LOG/key")" "$T_KEY"
assert_not_contains "the key is NOT in codex argv" "$(cat "$LOG/argv")" "$T_KEY"
assert_not_contains "the key is NOT in any artefact" "$(cat "$OUT_DIR"/* 2>/dev/null)" "$T_KEY"
assert_contains "argv ends with '-' (prompt from stdin)" "$(tail -n1 "$LOG/argv")" "-"
assert_contains "default sandbox is danger-full-access (the only mode that executes here)" "$(cat "$LOG/argv")" "danger-full-access"
rm -f "$REPO/codex-made.txt"

echo "=== 3. inherited stdin can neither block nor splice into the task ==="
echo "INJECTED-FROM-CALLER-STDIN" > "$WORK/stdin.txt"
T_STDIN="$WORK/stdin.txt" _run stdin
assert_rc "rc 0 with a non-tty stdin" "$RC" "0"
assert_not_contains "caller stdin did not reach codex" "$(cat "$LOG/stdin")" "INJECTED-FROM-CALLER-STDIN"
rm -f "$REPO/codex-made.txt"

echo "=== 4. --allow-dirty: pre-existing edits are NOT attributed to codex ==="
echo "operator edit" >> "$REPO/base.txt"
_run dirty-refused
assert_rc "dirty tree without --allow-dirty -> rc 6" "$RC" "6"
_run dirty-ok --allow-dirty
assert_rc "dirty tree with --allow-dirty -> rc 0" "$RC" "0"
assert_not_contains "operator's own edit absent from diff.patch" "$(cat "$OUT_DIR/diff.patch")" "operator edit"
assert_contains "codex's edit present in diff.patch" "$(cat "$OUT_DIR/diff.patch")" "codex-made.txt"
git -C "$REPO" checkout -q -- base.txt; rm -f "$REPO/codex-made.txt"

echo "=== 5. workdir must be a repo ROOT ==="
mkdir -p "$REPO/sub"; echo x > "$REPO/sub/k"; git -C "$REPO" add sub/k; git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m sub
T_CD="$REPO/sub" _run subdir
assert_rc "a subdirectory of a repo -> rc 6 (no walk-up)" "$RC" "6"
mkdir -p "$WORK/plain"
T_CD="$WORK/plain" _run plain --no-git
assert_rc "--no-git on a plain dir -> rc 0" "$RC" "0"
assert_contains "--no-git passes --skip-git-repo-check" "$(cat "$LOG/argv")" "--skip-git-repo-check"

echo "=== 6. the verdict comes from the EVENT, not from codex's rc ==="
T_MODE=failed _run failed
assert_rc       "turn.failed -> rc 3" "$RC" "3"
assert_contains "the failure message is surfaced" "$OUT" "Quota exceeded"
T_MODE=no-terminal _run noterm
assert_rc       "rc 0 with NO terminal event -> rc 7 indeterminate, never completed" "$RC" "7"
T_MODE=ok-rc1 _run okrc1
assert_rc       "turn.completed with process rc 1 -> rc 0" "$RC" "0"
assert_contains "…and the process rc is reported, not hidden" "$OUT" "codex process rc 1 despite turn.completed"

echo "=== 7. timeout is the wrapper's verdict, typed ==="
T_MODE=hang T_TIMEOUT=2 _run hang
assert_rc       "--timeout expiry -> rc 4" "$RC" "4"
assert_contains "verdict names timeout" "$OUT" "verdict=timeout"

echo "=== 8. unavailable: no binary, no credential ==="
T_BIN="$WORK/no-such-codex" _run nobin
assert_rc "CODEX_BIN not executable -> rc 5" "$RC" "5"
T_KEY="" _run nokey
assert_rc "no key and no auth.json -> rc 5" "$RC" "5"
mkdir -p "$WORK/codexhome"; echo '{"auth_mode":"apikey"}' > "$WORK/codexhome/auth.json"
T_KEY="" _run authjson
assert_rc "no key but an auth.json login -> rc 0" "$RC" "0"
assert_eq "…and nothing injects CODEX_API_KEY" "$(cat "$LOG/key")" ""
rm -f "$WORK/codexhome/auth.json" "$REPO/codex-made.txt"

echo "=== 9. version drift is reported; a blank local pin is not the floor ==="
T_VER=1.0.0 _run drift
assert_contains "installed != expected warns" "$(cat "$OUT_DIR.stderr")" "codex version 1.0.0 != expected 9.9.9"
mkdir -p "$WORK/state"; : > "$WORK/state/codex-version-local"
_run blankpin
assert_eq "an EMPTY local pin reads <unreadable-pin>, not the 9.9.9 floor" "$(awk -F= '$1=="expected_version"{print $2}' "$OUT_DIR/status")" "<unreadable-pin>"
rm -f "$WORK/state/codex-version-local" "$REPO/codex-made.txt"

echo "=== 9b. the diff's boundary is stated, and what lies outside it is listed (skeptic F3) ==="
echo "build/" > "$REPO/.gitignore"; git -C "$REPO" add .gitignore; git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m ignore
# Age the fixture's own write: the run's marker is back-dated one second (the
# documented safe-direction over-listing), so a file written in the second
# before the run would be listed too.
touch -d '@1000000000' "$REPO/.gitignore"
mkdir -p "$WORK/outside"
T_MODE=wide _run wide --also-watch "$WORK/outside"
assert_rc       "wide writes -> rc 0" "$RC" "0"
assert_not_contains "diff.patch cannot hold the gitignored write" "$(cat "$OUT_DIR/diff.patch")" "build/cache"
assert_contains "…but writes-outside-diff.txt lists it" "$(cat "$OUT_DIR/writes-outside-diff.txt")" "/build/cache"
assert_contains "…and the --also-watch write outside --cd" "$(cat "$OUT_DIR/writes-outside-diff.txt")" "$WORK/outside/outside.txt"
assert_contains "the verdict line names the count, not just the diff" "$OUT" "writes_outside_diff=2 "
assert_contains "commands.txt lists what codex ran" "$(cat "$OUT_DIR/commands.txt")" $'exit=0\tmake build'
rm -rf "$REPO/codex-made.txt" "$REPO/build" "$WORK/outside/outside.txt"
T_MODE=wide _run wide-unwatched
assert_eq "UNWATCHED: the outside write is in NO list (commands.txt is the only witness) — the boundary, measured" \
    "$(grep -c 'outside.txt' "$OUT_DIR/writes.txt" || true)" "0"
rm -rf "$REPO/codex-made.txt" "$REPO/build" "$WORK/outside/outside.txt"

echo "=== 10. --dry-run runs nothing; --out refuses to mix runs ==="
: > "$LOG/argv"
_run dry --dry-run
assert_rc       "--dry-run -> rc 0" "$RC" "0"
assert_contains "--dry-run prints the exec argv" "$OUT" " exec "
assert_eq       "--dry-run did not invoke codex" "$(cat "$LOG/argv")" ""
mkdir -p "$WORK/out-full"; echo x > "$WORK/out-full/keep"
_run full
assert_rc       "non-empty --out -> rc 2" "$RC" "2"

EXPECTED_ASSERTIONS=50
TOTAL_ASSERTIONS=$(( PASS + FAIL + ${SKIP:-0} ))
if (( TOTAL_ASSERTIONS != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi
th_summary_and_exit
