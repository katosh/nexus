#!/usr/bin/env bash
# Opt-in test helpers: shared assertion primitives + PASS/FAIL
# counters + summary footer + fake-nexus fixture builder.
#
# Existing tests under monitor/watcher/test-*.sh use inline
# assertions for self-containment. New tests MAY source this file
# instead of redefining assert_*:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
#
#   assert_eq         "label" "$got" "$want"
#   assert_contains   "label" "$haystack" "$needle"
#   assert_not_contains "label" "$haystack" "$needle"
#   assert_empty      "label" "$value"
#   assert_file_exists "label" "$path"
#   assert_no_file     "label" "$path"
#
#   # Fixture builder (issue #37) — populates a fake nexus tree
#   # with `monitor/ng`, a config/load.sh stub, and a mint-token.sh
#   # stub. Sets the global $FAKE_NEXUS to the populated dir.
#   setup_fake_nexus "$WORK/nexus" [--token <str>] [--repo <owner/name>] \
#                                  [--user <login>] [--allow-default]
#
#   # GH-stub fixture builder (issue #38) — generates a PATH-shadow
#   # `gh` script that captures every argv to a file and dispatches
#   # `gh api` calls to a caller-supplied case body keyed on the
#   # extracted endpoint:
#   make_gh_stub <stub-path> <capture-path> [--with-body-capture <path>] <<'CASES'
#       */issues/*/comments)  printf '{"html_url":"https://x/c"}' ;;
#       *)                    printf '{}' ;;
#   CASES
#
#   # Hermetic-env wrapper (issue #41) — unsets the five operator-side
#   # vars that can redirect production code into the real nexus
#   # tree, then runs the command:
#   run_hermetic VAR=val ... -- <cmd> [args...]
#
#   # ... at end of file:
#   th_summary_and_exit
#
# Counters are exported as PASS / FAIL globals. test_helpers does
# not call `set -uo pipefail` — sourcing test is responsible for
# its own shell options.

# bash 5.2 enables `patsub_replacement` by default, which makes `&`
# in the replacement string of `${var//pat/rep}` expand to the
# matched text. `make_gh_stub` feeds case bodies (which legitimately
# contain `&` in shapes like `&&` inside `[[ ]]` guards and `>&2`)
# through such a substitution to build the generated stub. With the
# option on, the resulting stub becomes syntactically broken — bash
# parses `>&2` as `>@@CASES@@2` and `&&` as `@@CASES@@@@CASES@@`,
# the stub fails to start, every `gh` call returns nonzero, and the
# ng-tests fail in mysterious "got 1 want 0" ways only on bash 5.2+.
# Force it off; bash 4.x doesn't know the option and silently no-ops.
shopt -u patsub_replacement 2>/dev/null || true

# Disarm Lmod's command_not_found_handle in the sourcing test shell
# (your-org/nexus-code#457/#479/#480). On the sandbox hosts BASH_ENV
# reaches Lmod's init, which arms a handler that shells out to
# `command_not_found.py` via PATH; bash forks a child before invoking
# it, so a test shell that narrows PATH past the dir holding that
# script turns any missing command into an unbounded fork chain (the
# 2026-07-08 pid_max exhaustion). Tests never rely on the handler —
# a missing command should be a plain rc=127. This guards the SOURCING
# shell only; bash children each re-arm from BASH_ENV, so PATHs handed
# to children go through th_hermetic_path below instead.
unset -f command_not_found_handle 2>/dev/null || true

# Public-template disable switch: the public-mirror tree ships a
# monitor/_public-guard.sh whose call sites make every bring-up entry
# point (bootstrap-recover.sh, bootstrap-install.sh, watcher/entry.sh)
# refuse with "nexus is disabled" unless NEXUS_PUBLIC_ENABLED=1. The
# unit suite executes those entry points against fixture-local state
# (stubbed labsh, tmpdir registries) — the sanctioned unlock, not a
# bypass of the guard's purpose (blocking ACCIDENTAL autonomous
# bring-up on a fork). Without it the mirror's CI reds on any
# helper-sourcing test that runs a guarded script for real (the
# bootstrap-recover stanza of test-jupyter-service.sh). On a tree
# that ships no guard the export is inert; the mirror's Pages workflow
# separately asserts the guard still fires without this variable.
export NEXUS_PUBLIC_ENABLED=1

: "${PASS:=0}"
: "${FAIL:=0}"

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    fi
}

assert_empty() {
    local label="$1" got="$2"
    if [[ -z "$got" ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected empty, got %q\n' "$label" "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing file: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_no_file() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — file unexpectedly present: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# --- fork-bomb precondition guard (your-org/nexus-code#479 / #457) -----
#
# Lmod's init (/app/lmod/lmod/init/bash, reached via BASH_ENV on the
# sandbox hosts) arms a `command_not_found_handle` that runs
# `command_not_found.py "$1"` — resolved via PATH, and the ONLY copy
# lives in /app/bin. Bash forks a child before invoking the handler,
# so when command_not_found.py is ITSELF unresolvable the handler
# re-fires inside the forked child, which forks again: an unbounded
# parent→child chain, each level blocked in wait(), that exhausted the
# node's pid_max on 2026-07-08 (#457). It is a conjunction — the armed
# handler is harmless while command_not_found.py resolves; a test that
# composes a synthetic PATH from absolute dirs supplies the missing
# half. Every PATH handed to a spawned child must therefore go through
# this helper.
#
# th_hermetic_path <base-path> <scratch-dir>
#
# Echo <base-path>, augmented so command_not_found.py stays resolvable:
# if it resolves on the AMBIENT PATH but not on <base-path>, append a
# private dir under <scratch-dir> holding ONLY a symlink to it. The
# fork-recursion primitive is defused without leaking any other host
# tool into the hermetic PATH. Off-sandbox (CI: no Lmod, no
# command_not_found.py) the base path is returned unchanged.
th_hermetic_path() {
    local base="$1" scratch="$2" cnf dir
    cnf=$(command -v command_not_found.py 2>/dev/null) \
        || { printf '%s' "$base"; return 0; }
    if PATH="$base" command -v command_not_found.py >/dev/null 2>&1; then
        printf '%s' "$base"; return 0
    fi
    dir="$scratch/th-cnf-bin"
    mkdir -p "$dir"
    ln -sf "$cnf" "$dir/command_not_found.py"
    printf '%s:%s' "$base" "$dir"
}

# th_assert_path_resolves_cnf <label> <path-string>
#
# Regression assertion for the same class: on hosts where
# command_not_found.py resolves ambiently, the given PATH must keep it
# resolvable (fails on a bare absolute-dir composition, passes once the
# construction goes through th_hermetic_path). Vacuously passes
# off-sandbox, where the mechanism cannot arm at all.
th_assert_path_resolves_cnf() {
    local label="$1" p="$2"
    if ! command -v command_not_found.py >/dev/null 2>&1; then
        printf '  PASS: %s (vacuous: no command_not_found.py on this host)\n' "$label"
        PASS=$(( PASS + 1 )); return 0
    fi
    if PATH="$p" command -v command_not_found.py >/dev/null 2>&1; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — command_not_found.py unresolvable on: %s\n' "$label" "$p" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# --- identity-verified kills (PID-recycling guard) ---------------------
#
# pid_max on the lab boxes is small (36864 observed) and a parallel
# suite run forks hundreds of processes per second, so the PID space
# wraps in well under a minute. A cleanup that kills a PID recorded
# earlier (pidfile, $!) whose process has since exited will, after a
# wrap, deliver the signal to whatever innocent process now owns the
# number — observed in the R3-tail stress campaign as a sibling
# test's subprocess dying silently (SIGKILL leaves no stderr; the
# victim assertion just reads as false). Both helpers therefore
# verify the CURRENT owner's identity via /proc before signalling,
# and refuse (rc 1, no kill) when identity can't be confirmed —
# leaking a short-lived helper is recoverable, killing a stranger's
# process is not. The check-then-kill window shrinks the race from
# minutes to microseconds; it cannot close it entirely.

# th_kill_fixture_pid <pid> <fixture-root> [<sig>] [--group]
#
# Signal <pid> only if its /proc cmdline or cwd still points into
# <fixture-root> (every per-test fixture dir is unique, so a recycled
# PID can't match). --group additionally signals the process group
# <pid> leads (for setsid'd fixture supervisors).
th_kill_fixture_pid() {
    local pid="$1" root="$2" sig="${3:-TERM}" group="${4:-}"
    [[ "$pid" =~ ^[0-9]+$ && -n "$root" ]] || return 1
    local cmdline cwd
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || cmdline=""
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=""
    [[ "$cmdline" == *"$root"* || "$cwd" == "$root"* ]] || return 1
    [[ "$group" == "--group" ]] && kill "-$sig" -- "-$pid" 2>/dev/null
    kill "-$sig" "$pid" 2>/dev/null
}

# th_kill_own_child <pid> [<sig>]
#
# Signal <pid> only while it is still a child of THIS shell (its
# /proc ppid equals $$). Once the child has been reaped its PID is
# recyclable and the new owner's ppid is somebody else, so the guard
# refuses. Zombies keep their ppid, so an exited-but-unreaped child
# is still (harmlessly) signalable.
th_kill_own_child() {
    local pid="$1" sig="${2:-TERM}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    local stat rest ppid
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    rest="${stat##*) }"            # strip "pid (comm) " — comm may hold ')'
    read -r _state ppid _ <<<"$rest"
    [[ "$ppid" == "$$" ]] || return 1
    kill "-$sig" "$pid" 2>/dev/null
}

th_summary_and_exit() {
    echo
    printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
    if (( FAIL == 0 )); then
        echo "ALL TESTS PASSED"
        exit 0
    fi
    exit 1
}

# Populate <work-dir> with a minimal fake nexus tree:
#   <work-dir>/monitor/ng                  — copy of monitor/ng
#   <work-dir>/monitor/mint-token.sh       — echoes the configured token
#   <work-dir>/config/load.sh              — answers github.repo and
#                                            github.user_login; other keys
#                                            exit 2 (default) or fall
#                                            through to "$2" with
#                                            --allow-default.
#   <work-dir>/reports/                    — empty dir for upload tests
#
# Side effect: sets the global $FAKE_NEXUS to <work-dir>.
#
# Consolidates the 7-file duplication flagged by the watcher
# test-suite audit (your-org/nexus-code#37). Tests that need
# non-default stub behavior (e.g. an erroring mint-token) can call
# this helper first and then overwrite the generated files.
setup_fake_nexus() {
    local work_dir="$1"; shift
    local token='fake-installation-token'
    local repo='default-org/default-repo'
    local user='test-user'
    local allow_default=0
    while (( $# > 0 )); do
        case "$1" in
            --token)         token="$2"; shift 2 ;;
            --repo)          repo="$2"; shift 2 ;;
            --user)          user="$2"; shift 2 ;;
            --allow-default) allow_default=1; shift ;;
            *)
                printf 'setup_fake_nexus: unknown flag %q\n' "$1" >&2
                return 2
                ;;
        esac
    done

    # `ng` lives at monitor/ng; we are at monitor/watcher/_test_helpers.sh.
    local _th_dir _ng_src
    _th_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    _ng_src="$_th_dir/../ng"
    if [[ ! -f "$_ng_src" ]]; then
        printf 'setup_fake_nexus: ng not found at %s\n' "$_ng_src" >&2
        return 2
    fi

    FAKE_NEXUS="$work_dir"
    mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config" "$FAKE_NEXUS/reports"
    cp "$_ng_src" "$FAKE_NEXUS/monitor/ng"

    # The config stub interpolates $repo and $user at write time;
    # ${1:-} etc. stay as shell syntax in the generated stub.
    if (( allow_default )); then
        cat > "$FAKE_NEXUS/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)        printf '%s' '$repo' ;;
    github.user_login)  printf '%s' '$user' ;;
    *) [[ \$# -ge 2 ]] && { printf '%s' "\$2"; exit 0; }; exit 2 ;;
esac
STUB
    else
        cat > "$FAKE_NEXUS/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)        printf '%s' '$repo' ;;
    github.user_login)  printf '%s' '$user' ;;
    *) exit 2 ;;
esac
STUB
    fi
    chmod +x "$FAKE_NEXUS/config/load.sh"

    cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<STUB
#!/usr/bin/env bash
printf '%s' '$token'
STUB
    chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"
}

# Generate a PATH-shadow `gh` stub. The stub captures every `gh ...`
# invocation's argv to <capture-path> (one line per call) and, for
# `gh api ...` calls, walks argv to extract `$endpoint` (the first
# positional starting with `/`) and `$method` (from `-X METHOD`,
# default `GET`), then dispatches to the caller-supplied case body
# read from stdin. The case body has `$endpoint` and `$method` in
# scope and is responsible for printing the canned response to
# stdout.
#
# --with-body-capture <path>: when set, the stub captures stdin (the
# request body piped via `--input -`) to <path>. Without it, stdin
# is drained to /dev/null to keep upstream from SIGPIPEing. Tests
# that need to assert on the request body opt in via this flag.
#
# Argv walker shape consolidates the three existing stub variants:
# `-X` is 2-arg (method); `-H -f --input` are 2-arg (drained);
# `--paginate` is 1-arg; bare `/path` positional is the endpoint;
# other tokens are skipped. Closes your-org/nexus-code#38.
make_gh_stub() {
    local stub_path="$1" capture_path="$2"; shift 2
    local body_capture=""
    while (( $# > 0 )); do
        case "$1" in
            --with-body-capture) body_capture="$2"; shift 2 ;;
            *)
                printf 'make_gh_stub: unknown flag %q\n' "$1" >&2
                return 2
                ;;
        esac
    done

    local cases_body
    cases_body=$(cat)

    # Quoted-literal limiter ('STUB') keeps every $... and backslash
    # in the template literal; placeholders are substituted afterward.
    local template
    template=$(cat <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> @@CAPTURE@@
if [[ "${1:-}" != "api" ]]; then exit 0; fi
shift
method="GET"
endpoint=""
while (( $# > 0 )); do
    case "$1" in
        -X)            method="$2"; shift 2 ;;
        -H|-f|--input) shift 2 ;;
        --paginate)    shift ;;
        --)            shift; break ;;
        /*)            endpoint="$1"; shift ;;
        -*)            shift ;;
        *)             shift ;;
    esac
done
@@STDIN@@
case "$endpoint" in
@@CASES@@
esac
exit 0
STUB
)

    local stdin_block
    if [[ -n "$body_capture" ]]; then
        stdin_block=$(printf 'if ! [ -t 0 ]; then cat > %q 2>/dev/null || true; else : > %q; fi' \
            "$body_capture" "$body_capture")
    else
        stdin_block='if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi'
    fi

    # Quote the capture path so paths with spaces survive.
    local capture_quoted
    capture_quoted=$(printf '%q' "$capture_path")

    # ${VAR//PAT/REP} doesn't process backslashes inside REP for
    # literal substitution; safe for the case body the caller passes.
    template=${template//@@CAPTURE@@/$capture_quoted}
    template=${template//@@STDIN@@/$stdin_block}
    template=${template//@@CASES@@/$cases_body}

    mkdir -p "$(dirname "$stub_path")"
    printf '%s\n' "$template" > "$stub_path"
    chmod +x "$stub_path"
}

# Run a command with hermetic env. Unsets the five operator-side
# variables that can redirect production code (`monitor/ng`,
# `monitor/watcher/*`) into the real nexus tree:
#
#   TMUX, TMUX_PANE  — tmux context; production code branches on these
#   NEXUS_ROOT       — root path; ng's state-dir resolver reads this
#   NEXUS_CONFIG     — config-yaml path; load.sh reads this
#   HOME             — production code reaches into $HOME/.claude/
#                      (session-id lookup, projects/ enumeration)
#
# Caller pins replacements via inline VAR=value pairs before the
# `--` separator. Without `--` the helper would have no clean way to
# distinguish env assignments from the command being launched.
#
# Usage:
#   run_hermetic NEXUS_STATE_DIR="$STATE_DIR" PATH="$STUB_DIR:$PATH" \
#       -- "$NG" wrap-up 42 "$report"
#
# Audit cross-reference: gold-standard pattern is
# `test-ng-wrap-up.sh:243-254` (post-#41 sweep). Existing tests with
# partial `env -u` insertions migrate by either calling this helper
# or by adding the missing `-u` flags inline. See your-org/nexus-code#41.
run_hermetic() {
    local -a env_args=()
    while (( $# > 0 )); do
        case "$1" in
            --) shift; break ;;
            *=*) env_args+=("$1"); shift ;;
            *)
                printf 'run_hermetic: expected VAR=val or --, got %q\n' "$1" >&2
                return 2
                ;;
        esac
    done
    if (( $# == 0 )); then
        printf 'run_hermetic: no command after --\n' >&2
        return 2
    fi
    env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
        "${env_args[@]}" "$@"
}
