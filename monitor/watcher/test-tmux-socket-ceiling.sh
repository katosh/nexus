#!/usr/bin/env bash
# The tmux SOCKET-PATH ceiling, executed rather than asserted
# (your-org/nexus-code#991).
#
# Run: bash monitor/watcher/test-tmux-socket-ceiling.sh
# Expected: ALL TESTS PASSED, exit 0.
#
# WHAT WENT WRONG. A `TMUX_TMPDIR` longer than `sun_path` can hold makes every
# `tmux -L` call die `File name too long`. A suite reads that as "tmux is
# unavailable", takes its precondition branch, and reports FAIL — so an
# ENVIRONMENT fault presents as a defect in the code under test. Five suites
# went red that way in one session, five attributions were wrong, and one
# published finding had to be retracted. It reproduces identically on every
# tree, so the standard "does clean `dev` fail too?" triage answers YES and
# means the opposite of what it is read to mean.
#
# WHY A SUITE AND NOT A COMMENT. Every claim below is a claim about a BINARY
# (tmux) and a KERNEL (AF_UNIX), neither of which this repo controls. Prose
# describing them cannot be made to fail when they change; this can.
#
# ── THE OFF-BY-ONE THAT MAKES §1 THE LOAD-BEARING SECTION ────────────────
#
# Everyone, including `#991` itself, quotes a "108-byte limit". `sun_path` is
# 108 bytes, and the longest path a NUL-TERMINATING caller can bind is **107**.
# A guard implemented straight from the received wording — `len <= 108` —
# passes exactly the boundary path that fails, and its author has no reason to
# look again. §1 pins both sides of that boundary against a real bind AND
# against real tmux, and §7 asserts the constant this repo ships is 107 rather
# than the number the literature repeats.
#
# THE MECHANISM IS THE CALLING CONVENTION, NOT THE KERNEL, and this header said
# otherwise until an independent re-derivation refuted it. Measured in C on this
# host, varying ONLY `addrlen`: at len=108 the NUL-terminated convention
# (`offsetof + strlen + 1`) gives EINVAL while `sizeof(struct sockaddr_un)`
# BINDS; at len=109 the path does not fit at all. So 108 IS bindable by the
# kernel. 107 remains the right number to ship — tmux, python and everything
# C-string-shaped use the terminating convention — but "the kernel rejects 108"
# is false and would mislead anyone applying it to another caller. The assertions
# below deliberately measure the convention that ACTUALLY BINDS TMUX, which is
# the one this repo depends on.
#
# ── NON-VACUITY ─────────────────────────────────────────────────────────
#
#   Control A — every "too long" assertion is paired with a FITTING control
#               that must SUCCEED. A suite in which nothing can bind would
#               otherwise pass every negative assertion by accident, which is
#               `#618`'s own shape.
#   Control B — the negative control must fail FOR THE EXPECTED REASON. §1
#               matches `File name too long` / `too long`, never merely
#               "non-zero rc": a tmux that died of anything else is not
#               evidence about path length.
#   Control C — §5's refusal is checked for rc **78** AND for the measured
#               number in its text. A refusal that fires without naming the
#               length is the defect this whole change exists to remove,
#               reintroduced inside its own remedy.
#
# ── COVERAGE BOUNDARY, on the axis the MECHANISM varies on ───────────────
#
# The mechanism varies on the KERNEL's `sun_path` size and on TMUX's socket
# COMPOSITION rule — not on this repo's files. So this suite is a claim about
# THIS HOST's tmux and kernel, printed on every failure. It says nothing about
# `tmux -S <path>` (which names the socket outright, composing nothing) and
# nothing about a bare `tmux` inside a pane (where `$TMUX` supplies the socket
# and `TMUX_TMPDIR` is never consulted). Those are different code paths in
# tmux, not different lengths, and no length assertion reaches them.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
LIB="$_test_dir/../_tmux_socket.sh"
CLI="$_test_dir/../tmux-socket-fits.sh"
RUNNER="$_test_dir/run-tests.sh"

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
# What this guard READS to reach its verdict: the library it exercises, the
# CLI wrapper, the helper that carries the refusal, the runner that carries the
# pre-flight, and the suites wired to the helper. Declared by ENUMERATION
# (`git grep` for the call), never by a hand-typed list — a copy of a
# population is a population that drifts.
. "$_test_dir/../_guard_population.sh"
# WHICH SUITES ACTUALLY DRIVE A REAL TMUX SERVER — enumerated by MECHANISM.
#
# Three predicates were measured over the 330 depth-1 suites at this ref, and
# they disagree, which is the whole reason this is a function and not a list:
#
#   `tmux …-L/-S` on a non-comment line   ->  8   MISSES `"$REAL_TMUX" -L "$SOCK"`
#   `new-session`, quoted spans stripped  -> 14   ADDS two suites whose only
#                                                 `new-session` is in a COMMENT
#   `new-session`, quotes AND comments    -> 12   <- the mechanism
#
# The 14-form's two extras (`test-launcher-headless.sh`,
# `test-launcher-pidfile.sh`) name the verb inside a prose comment about a stub;
# the 8-form's misses invoke tmux through a resolved-binary variable. Neither
# error announces itself, and the union of two wrong predicates is not the right
# one — so the quote state machine is borrowed from `_shell_quotes.awk` (ONE
# implementation, `#842`) and comment-stripping is added on top of it.
#
# `:(glob)` on the pathspec because git's `*` CROSSES `/` (`#954`): without it
# the corpus silently grows to include `test-integration/`, whose harness this
# suite is not allowed to run.
_TSC_QUOTES_AWK="$_test_dir/_shell_quotes.awk"
_tsc_realtmux() {
    [ -r "$_TSC_QUOTES_AWK" ] || return 1
    ( cd "$REPO_ROOT" && git ls-files -- ':(glob)monitor/watcher/test-*.sh' ) \
    | ( cd "$REPO_ROOT" && xargs awk "$(cat "$_TSC_QUOTES_AWK")"'
        function code_no_comment(s,   m, i, L, out, c, p) {
            m = quote_mask(s); L = length(s); out = ""
            for (i = 1; i <= L; i++) {
                c = substr(s, i, 1)
                if (substr(m, i, 1) == "1") continue
                p = (i > 1) ? substr(s, i-1, 1) : " "
                if (c == "#" && (p == " " || p == "\t" || i == 1)) break
                out = out c
            }
            return out
        }
        { if (code_no_comment($0) ~ /new-session/) { print FILENAME; nextfile } }' ) \
    | grep -v '^monitor/watcher/test-tmux-socket-ceiling\.sh$' \
    | sort
}
# _tsc_calls <file> <fn> -> rc 0 iff <fn> appears in COMMAND POSITION.
#
# NOT `grep -q <fn> <file>`. That is a MENTION grep, and this file's own §8
# header cites CLAUDE.md's `ps`-matching entry — "a predicate keyed on a STRING
# cannot tell the THING from the DESCRIPTION of the thing" — to justify
# excluding this suite from its own corpus. The wiring check eleven lines later
# then did exactly that, and a skeptic measured the cost:
# `test-cc-harness-socket-isolation.sh` mentions `cch_setup` ELEVEN times, all
# comments and assertion labels, calls NEITHER helper, drives real tmux, and
# scored as wired. Getting the class right in one place and wrong in the next is
# how it survives review.
#
# Command position means: start of a logical line, or after a `;`, `&&`, `||`,
# `|`, `(`, `{`, or a `then`/`do`/`else`/`elif` keyword — evaluated on the line
# with quoted spans and comments already removed by `code_no_comment`, the
# stripper this file already carries for its `new-session` enumeration.
_tsc_calls() {
    [ -r "$_TSC_QUOTES_AWK" ] || return 2
    awk "$(cat "$_TSC_QUOTES_AWK")"'
    function code_no_comment(s,   m, i, L, out, c, p) {
        m = quote_mask(s); L = length(s); out = ""
        for (i = 1; i <= L; i++) {
            c = substr(s, i, 1)
            if (substr(m, i, 1) == "1") continue
            p = (i > 1) ? substr(s, i-1, 1) : " "
            if (c == "#" && (p == " " || p == "\t" || i == 1)) break
            out = out c
        }
        return out
    }
    { c = code_no_comment($0)
      if (c ~ ("(^|[;&|(){}]|[ \t](then|do|else|elif))[ \t]*" FN "([ \t]|$)")) { found = 1 }
    }
    END { exit(found ? 0 : 1) }' FN="$2" "$1"
}

gp_population() {
    printf '%s\n' monitor/_tmux_socket.sh monitor/tmux-socket-fits.sh \
                  monitor/watcher/_test_helpers.sh monitor/watcher/run-tests.sh \
                  monitor/watcher/_shell_quotes.awk \
                  monitor/watcher/test-claude-md-lstree-pathspec.sh
    _tsc_realtmux
}
gp_handle "$@"

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 77; }
[[ -r "$LIB" ]] || { echo "missing $LIB" >&2; exit 2; }

. "$LIB"
UID_N=$(id -u)
TMUXV=$(tmux -V 2>&1)
KERNEL=$(uname -r)

# Every fixture socket dir lives here — SHORT by construction, which is the
# whole subject of this file. Never $TMPDIR (whose length is decided by
# something other than this suite) and never the session scratchpad.
BASE="/tmp/tsc-$$"
mkdir -p "$BASE" || { echo "cannot create $BASE" >&2; exit 2; }

# Fixture servers are killed by EXPLICIT `-L` on a private socket, never by a
# bare kill-server: `bwrap` is PID 1 running the board's tmux under
# `--die-with-parent`, and an untargeted kill-server ends the sandbox
# (your-org/nexus-code#644).
_SERVERS=()
_reap() {
    local s
    for s in "${_SERVERS[@]:-}"; do
        [[ -n "$s" ]] || continue
        env -u TMUX TMUX_TMPDIR="${s%%|*}" tmux -L "${s##*|}" kill-server >/dev/null 2>&1
    done
    rm -rf "$BASE"
}
trap _reap EXIT

# start_server <tmpdir> <sockname>  -> rc 0 and records the server for reaping
start_server() {
    local d="$1" n="$2" out
    mkdir -p "$d"
    out=$(env -u TMUX TMUX_TMPDIR="$d" tmux -L "$n" new-session -d 'sleep 30' 2>&1) || {
        printf '%s' "$out"; return 1; }
    _SERVERS+=("$d|$n")
    return 0
}

# dir_for_total <total-path-bytes> <sockname>
# A directory under $BASE chosen so the COMPOSED socket path is exactly
# <total-path-bytes> long. The composition is the library's, not a second copy.
dir_for_total() {
    local want="$1" n="$2" fixed pad
    fixed=$(( ${#BASE} + 1 + 6 + ${#UID_N} + 1 + ${#n} ))   # BASE + / + tmux- + uid + / + name
    pad=$(( want - fixed ))
    (( pad >= 0 )) || { echo "dir_for_total: target $want too small" >&2; return 1; }
    printf '%s/%s' "$BASE" "$(python3 -c "import sys;sys.stdout.write('a'*int(sys.argv[1]))" "$pad")"
}

# assert_socket_exists <label> <path>
#
# NOT `assert_file_exists`, and the difference is the point. That helper tests
# `[[ -f ]]`, which is FALSE for a UNIX-domain socket — so every assertion here
# would have failed for a reason having nothing to do with tmux. It cost three
# reds on this suite's first run, which is the same defect class the suite is
# about: a check that asserts a property (`the socket is there`) while testing
# a proxy (`a regular file is there`).
assert_socket_exists() {
    # `sockpath`, not `path` — zsh ties `path` to $PATH (#945). bash does not,
    # and this file is bash, but the name is a trap worth not laying.
    local label="$1" sockpath="$2"
    if [[ -S "$sockpath" ]]; then
        printf '  PASS: %s\n' "$label"; _th_pass
    else
        printf '  FAIL: %s — no SOCKET at %s (type: %s)\n' "$label" "$sockpath" \
               "$(ls -ld -- "$sockpath" 2>&1 | tr '\n' ' ')" >&2
        _th_fail
    fi
}

echo "=== host: $TMUXV, kernel $KERNEL, uid $UID_N ==="

# ── §1  THE BOUNDARY IS 107, NOT 108 ────────────────────────────────────
echo '=== §1 sun_path: 107 binds, 108 does not — kernel and tmux agree ==='

# 1a. The kernel, directly. python3's socket.bind is the shortest path to the
#     syscall; the assertion is on the ERROR TEXT as well as the failure, so a
#     bind that died of permissions cannot pass as evidence about length.
py_boundary=$(python3 - "$BASE" <<'PY'
import socket, os, sys
base = sys.argv[1]
def attempt(n):
    p = base + "/" + "b"*(n - len(base) - 1)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.bind(p); os.unlink(p); return "ok"
    except OSError as e:
        return "err:%s" % e
    finally:
        s.close()
sys.stdout.write("%s %s" % (attempt(107), attempt(108)))
PY
) || py_boundary="PRODUCER-FAILED"
# The producer's rc is consulted (CLAUDE.md `fromisoformat` mode 2): a python
# that died would otherwise leave an empty capture and every match below would
# read as a clean, wrong answer.
assert_not_contains "§1a the boundary probe's producer ran" "$py_boundary" "PRODUCER-FAILED"
assert_eq          "§1a a 107-byte AF_UNIX path BINDS"      "${py_boundary%% *}" "ok"
assert_contains    "§1a a 108-byte AF_UNIX path fails, and for LENGTH" \
                   "${py_boundary#* }" "too long"

# 1b. The same boundary through tmux itself, which is what the suites use.
sn=p
d107=$(dir_for_total 107 "$sn"); d108=$(dir_for_total 108 "$sn")
assert_eq "§1b fixture path for 107 really measures 107" "$(tmux_socket_len "$sn" "$d107")" "107"
assert_eq "§1b fixture path for 108 really measures 108" "$(tmux_socket_len "$sn" "$d108")" "108"

if start_server "$d107" "$sn"; then
    _th_pass; printf '  PASS: §1b tmux STARTS on a 107-byte socket path (the fitting control)\n'
else
    _th_fail; printf '  FAIL: §1b tmux STARTS on a 107-byte socket path — it did not, under %s\n' "$TMUXV" >&2
fi
err108=$(start_server "$d108" "$sn" 2>&1) && err108="UNEXPECTED-SUCCESS"
assert_contains "§1b tmux REFUSES a 108-byte socket path, for LENGTH" "$err108" "too long"

# ── §2  THE COMPOSITION RULE ────────────────────────────────────────────
echo '=== §2 tmux composes ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<name> ==='
d2="$BASE/compose"; n2="compose-probe"
if start_server "$d2" "$n2"; then
    want=$(tmux_socket_path "$n2" "$d2")
    assert_socket_exists "§2 the library's composed path is where the socket really is" "$want"
else
    th_abort "§2 could not start a fixture server on a short path — nothing below is measurable"
fi

# ── §3  TMPDIR DOES NOT PARTICIPATE ─────────────────────────────────────
echo '=== §3 TMPDIR is not consulted; only TMUX_TMPDIR, else /tmp ==='
d3="$BASE/tmpdir-decoy"; n3="tmpdir-probe"; mkdir -p "$d3"
out3=$(env -u TMUX -u TMUX_TMPDIR TMPDIR="$d3" tmux -L "$n3" new-session -d 'sleep 30' 2>&1) && \
    _SERVERS+=("/tmp|$n3")
assert_no_file     "§3 nothing appeared under the decoy TMPDIR"  "$d3/tmux-$UID_N"
assert_socket_exists "§3 the socket landed under /tmp instead"     "/tmp/tmux-$UID_N/$n3"

# ── §4  -L HONOURS TMUX_TMPDIR EVEN WITH $TMUX SET ──────────────────────
#
# Not a digression. This repo records the socket-precedence rule as
# `-L`/`-S` > `$TMUX` > `TMUX_TMPDIR` > default (#644). That rule is about
# WHICH SERVER a bare call reaches. Read as a statement about which DIRECTORY
# an explicit `-L` resolves in — an easy misreading — it would make the whole
# computation above look unsound for exactly the callers it is written for.
echo '=== §4 an explicit -L still resolves inside TMUX_TMPDIR when $TMUX is set ==='
d4="$BASE/withtmux"; n4="withtmux-probe"; mkdir -p "$d4"
TMUX="${TMUX:-/tmp/tmux-$UID_N/default,1,0}" TMUX_TMPDIR="$d4" \
    tmux -L "$n4" new-session -d 'sleep 30' >/dev/null 2>&1 && _SERVERS+=("$d4|$n4")
assert_socket_exists "§4 the socket landed under TMUX_TMPDIR, not under \$TMUX's dir" \
                   "$(tmux_socket_path "$n4" "$d4")"

# ── §5  th_require_tmux_socket — THE THREE OUTCOMES ─────────────────────
echo '=== §5 the helper separates "cannot form an address" from "the code is broken" ==='
probe_helper() {   # <tmux_tmpdir> -> "<rc>|<stderr>"
    local d="$1" o rc
    o=$(TMUX_TMPDIR="$d" bash -c '
            . "'"$_test_dir"'/_test_helpers.sh" >/dev/null 2>&1
            th_require_tmux_socket "sockname-probe"
            echo REACHED-PAST-THE-GATE' 2>&1); rc=$?
    printf '%s|%s' "$rc" "$o"
}
fit=$(probe_helper "$BASE")
assert_eq       "§5 outcome 1: a fitting path returns and the suite proceeds" "${fit%%|*}" "0"
assert_contains "§5 outcome 1: control — execution really continued"          "${fit#*|}" "REACHED-PAST-THE-GATE"

longd=$(dir_for_total 400 "sockname-probe")
big=$(probe_helper "$longd")
assert_eq          "§5 outcome 2: a too-long path exits ${TH_RC_TMUX_SOCKET_REFUSED}, not 1"  "${big%%|*}" "$TH_RC_TMUX_SOCKET_REFUSED"
assert_not_contains "§5 outcome 2: control — execution did NOT continue"      "${big#*|}" "REACHED-PAST-THE-GATE"
assert_contains    "§5 outcome 2: the refusal names the MEASURED length"      "${big#*|}" "400 bytes"
assert_contains    "§5 outcome 2: the refusal names the usable maximum"       "${big#*|}" "$TMUX_SUN_PATH_MAX"
assert_contains    "§5 outcome 2: the refusal says it is NOT a code failure"  "${big#*|}" "NOT a failure of the code under test"
assert_contains    "§5 outcome 2: the refusal carries a remedy"               "${big#*|}" "export TMUX_TMPDIR="

# ── §6  THE RUNNER PRE-FLIGHT ───────────────────────────────────────────
#
# The environment is a property of the RUN, so the runner refuses ONCE before
# dispatching anything — otherwise every real-tmux suite in the list reddens
# separately and each red invites its own wrong attribution.
echo '=== §6 run-tests.sh refuses the whole run rather than dispatching doomed suites ==='
cheap="$_test_dir/test-claude-md-lstree-pathspec.sh"
if [[ -r "$cheap" ]]; then
    r_out=$(TMUX_TMPDIR="$longd" bash "$RUNNER" "$cheap" 2>&1); r_rc=$?
    assert_eq       "§6 a too-long TMUX_TMPDIR refuses the run with exit 2" "$r_rc" "2"
    assert_contains "§6 the runner's refusal names the ceiling"             "$r_out" "$TMUX_SUN_PATH_MAX"
    assert_not_contains "§6 control — no suite was dispatched"              "$r_out" "PASS  test-claude-md"

    o_out=$(TMUX_TMPDIR="$longd" NEXUS_TMUX_SOCKET_CHECK=off bash "$RUNNER" "$cheap" 2>&1); o_rc=$?
    assert_eq       "§6 the documented override runs the suite anyway"      "$o_rc" "0"
    assert_contains "§6 control — the override really dispatched it"        "$o_out" "test-claude-md-lstree-pathspec.sh"
else
    th_abort "§6 needs a cheap non-tmux suite to dispatch; $cheap is unreadable"
fi

# ── §7  THE CONSTANT THIS REPO SHIPS ────────────────────────────────────
echo '=== §7 the shipped constant is 107, not the 108 the literature repeats ==='
assert_eq "§7 TMUX_SUN_PATH_MAX is 107" "$TMUX_SUN_PATH_MAX" "107"
# A guard written to 108 would pass the 108-byte path §1b just proved fails.
# Asserted here so a future "correction" to 108 turns this red rather than
# quietly restoring the off-by-one.
c108=$(tmux_socket_len "$sn" "$d108")
if (( c108 > TMUX_SUN_PATH_MAX )); then
    _th_pass; printf '  PASS: §7 the shipped limit rejects the 108-byte path tmux rejected\n'
else
    _th_fail; printf '  FAIL: §7 the shipped limit ACCEPTS a %s-byte path tmux refuses\n' "$c108" >&2
fi
if [[ -x "$CLI" ]]; then
    cli_out=$("$CLI" --socket "$sn" --tmpdir "$d108" 2>&1); cli_rc=$?
    assert_eq       "§7 the CLI refuses the same path with exit 3" "$cli_rc" "3"
    assert_contains "§7 the CLI names the measured length"         "$cli_out" "108 bytes"
else
    th_abort "§7 $CLI is not executable"
fi

# ── §8  THE WIRING RATCHET ──────────────────────────────────────────────
#
# §5 proves the helper refuses. It does not prove anybody CALLS it, and a
# precondition nothing invokes is prose. So every real-tmux suite that already
# sources the helpers must either call `th_require_tmux_socket` itself, or route
# its tmux through `cch_setup`, which carries the same check at the line that
# DECIDES its socket directory.
# THIS SUITE EXCLUDES ITSELF, and the reason is not tidiness. It drives real
# tmux servers on paths it CONSTRUCTS to be too long — that is §1b's whole
# subject — so requiring it to refuse such a path would make it refuse its own
# fixtures. It is also a false positive of the wiring predicate for the reason
# CLAUDE.md gives for `ps`-matching: a predicate keyed on a STRING cannot tell
# the THING from the DESCRIPTION of it, and this file NAMES
# `th_require_tmux_socket` in §5's probe and in §8's own grep pattern without
# ever calling it. Leaving it in would score a self-satisfying pass.
#
# THE NUMBERS BELOW MOVED ONCE ALREADY, AND THE MOVE IS THE LESSON. On the run
# before this file was `git add`ed they read 12/7; staged, they read 13/8 — the
# same guard, the same commit, a different answer, because `git ls-files`
# enumerates the INDEX (your-org/nexus-code#1054). The honest provenance for a
# population count is therefore command + ref + WHETHER THE FILES WERE STAGED.
echo '=== §8 every helper-sourcing real-tmux suite carries the precondition ==='
realtmux_n=0; helper_n=0; unwired=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    realtmux_n=$(( realtmux_n + 1 ))
    grep -q '_test_helpers\.sh' "$REPO_ROOT/$f" || continue
    helper_n=$(( helper_n + 1 ))
    _tsc_calls "$REPO_ROOT/$f" 'th_require_tmux_socket' \
        || _tsc_calls "$REPO_ROOT/$f" 'cch_setup' \
        || unwired="$unwired $f"
done < <(_tsc_realtmux)

# A SILENT ZERO HERE WOULD READ AS A CLEAN BILL. The enumerator is an awk
# pipeline over a git listing; if either end fails it prints nothing, the loop
# runs zero times, `unwired` stays empty, and the assertion below passes having
# checked nothing. Pinning the total is what makes the emptiness impossible to
# mistake for cleanliness.
# THE NUMBER IS THE POLICED POPULATION, AND THE LABEL NOW SAYS SO. An
# independent re-derivation answered 13/8/5 against this suite's 12/7/5 and was
# RIGHT: the tree holds 13 real-tmux suites, and this file self-excludes (see
# above), so 12 is what this guard POLICES and 13 is what the repo CONTAINS.
# The first label said "the corpus enumerates 12 real-tmux suites at this ref",
# which is a claim about the repository and was false by one. A number is only
# as good as the population its label names.
# 13/8 since your-org/nexus-code#1528 added test-tmux-selection-restore.sh, a
# helper-sourcing real-tmux suite that calls th_require_tmux_socket (measured
# with the file STAGED, per the note above).
assert_eq "§8 this guard polices 13 real-tmux suites (14 in the tree, minus this one)" \
          "$realtmux_n" "13"
assert_eq "§8 …of which 8 source the helpers (9 of 14 including this one)" \
          "$helper_n"   "8"
assert_empty "§8 none of those 8 is missing the precondition"        "$unwired"

# THE PREDICATE MUST DISCRIMINATE, or the assertion above is the mention grep
# again wearing a new name. Two controls on a planted pair: a file that only
# NAMES the helper in a comment and a string must NOT count as calling it, and a
# file that calls it must. Without these, `_tsc_calls` returning 0 for
# everything would satisfy §8 for free.
_tsc_ctl="$BASE/callctl"; mkdir -p "$_tsc_ctl"
printf '%s\n' '# th_require_tmux_socket is mentioned here' \
               'echo "and th_require_tmux_socket here too"' > "$_tsc_ctl/mention.sh"
printf '%s\n' 'th_require_tmux_socket "$SOCK"' > "$_tsc_ctl/call.sh"
if _tsc_calls "$_tsc_ctl/mention.sh" 'th_require_tmux_socket'; then
    _th_fail; printf '  FAIL: §8 control — a MENTION was counted as a call (the #1032-class defect)\n' >&2
else
    _th_pass; printf '  PASS: §8 control — a comment/string MENTION is not counted as a call\n'
fi
if _tsc_calls "$_tsc_ctl/call.sh" 'th_require_tmux_socket'; then
    _th_pass; printf '  PASS: §8 control — a real call IS counted (the predicate is not vacuously strict)\n'
else
    _th_fail; printf '  FAIL: §8 control — a real call was NOT counted; §8 above proves nothing\n' >&2
fi

# THE BOUNDARY, PINNED AS A NUMBER RATHER THAN DESCRIBED. The remaining real-tmux
# suites source no helpers, so they cannot call the helper and are covered only
# by `run-tests.sh`'s pre-flight — still exposed when invoked DIRECTLY. Recorded
# as data because prose cannot be made to fail: if this grows, somebody decides
# deliberately instead of inheriting it.
assert_eq "§8 the uncovered residue is 5 suites that source no helpers" \
          "$(( realtmux_n - helper_n ))" "5"

# THREE OF THE THIRTEEN ARE `SLOW_TESTS`-GATED and exit 77 in a default run, so
# they never reach a tmux call and cannot demonstrate the ceiling unless
# `SLOW_TESTS=1`. Recorded because a green default run proves nothing about
# them, and "these suites fail on a too-long socket path" is conditional for
# that third of the population.
slow_gated=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -q 'SLOW_TESTS' "$REPO_ROOT/$f" && slow_gated=$(( slow_gated + 1 ))
done < <(_tsc_realtmux)
assert_eq "§8 3 of the policed suites are SLOW_TESTS-gated (a default run skips them)" \
          "$slow_gated" "3"

# ── §9  THE NEW DEPENDENCY MUST NOT BREAK AN ISOLATED FIXTURE ───────────
#
# `_test_helpers.sh` now sources `monitor/_tmux_socket.sh`, and
# `test-helper-honesty.sh` copies `_test_helpers.sh` ALONE into a fixture tree
# with no sibling `monitor/`. An unconditional `.` printed `No such file or
# directory` there and left `tmux_socket_verdict` undefined — a half-defined
# helper, which is worse than an absent one.
#
# The contract is therefore: QUIET at source time (a fixture that never asks a
# socket question is not broken by the absence) and LOUD at the only point
# where the absence can produce a wrong answer.
echo '=== §9 the library being unreachable refuses at CALL time, silently at SOURCE time ==='
iso="$BASE/isolated/monitor/watcher"
mkdir -p "$iso"
cp "$_test_dir/_test_helpers.sh" "$iso/"
iso_src_err=$(bash -c ". '$iso/_test_helpers.sh' >/dev/null" 2>&1)
assert_empty "§9 sourcing the helpers without the library is SILENT" "$iso_src_err"
iso_out=$(bash -c ". '$iso/_test_helpers.sh' >/dev/null 2>&1
                   th_require_tmux_socket probe
                   echo REACHED-PAST-THE-GATE" 2>&1); iso_rc=$?
assert_eq       "§9 …but CALLING it exits ${TH_RC_TMUX_SOCKET_REFUSED}" "$iso_rc" "$TH_RC_TMUX_SOCKET_REFUSED"
assert_contains "§9 …naming the library it could not reach"             "$iso_out" "_tmux_socket.sh is unreachable"
assert_not_contains "§9 control — execution did NOT continue"           "$iso_out" "REACHED-PAST-THE-GATE"

echo '=== §10 nx_tmux_fixture_init never derives its socket root from the workdir or a long TMUX_TMPDIR (#1481) ==='
# The fixture used to put its socket dir at <workdir>/tt, and every caller
# builds <workdir> with `mktemp -d -t` — under $TMPDIR. When run-tests.sh gave
# each suite a private TMPDIR under its log directory, every tmux fixture blew
# sun_path and all six CI bands went red. Plant that exact shape: a workdir
# 120+ bytes deep AND a TMUX_TMPDIR that is itself too long, and require the
# fixture to land somewhere that fits, in a subshell so nothing leaks out.
. "$_test_dir/_tmux-fixture.sh"
_s10w=$(mktemp -d); _deep="$_s10w/$(printf 'deep-%.0s' $(seq 1 12) | tr ' ' '-')/x"; mkdir -p "$_deep"
_s10=$(TMUX_TMPDIR="$_deep" bash -c '
    . "'"$_test_dir"'/_test_helpers.sh" >/dev/null 2>&1
    . "'"$_test_dir"'/_tmux-fixture.sh" >/dev/null 2>&1
    if nx_tmux_fixture_init "'"$_deep"'" 2>/dev/null; then echo "rc=0"; else echo "rc=$?"; fi
    echo "root=$NX_TMUX_TMPDIR"
    tmux_socket_verdict nexus-test-XXXXX-XX "$NX_TMUX_TMPDIR" >/dev/null 2>&1 && echo fits=yes || echo fits=no
' 2>/dev/null)
assert_contains "§10 the fixture initialises under a too-long TMUX_TMPDIR and a deep workdir (rc 0)" "$_s10" "rc=0"
assert_not_contains "§10 …and its socket root is NOT under the workdir" "$(sed -n 's/^root=//p' <<<"$_s10")" "$_deep"
assert_contains "§10 …and the socket path it yields FITS by the shared helper" "$_s10" "fits=yes"
_short="$(tmux_socket_short_tmpdir "s10-$$")"; mkdir -p "$_short"
_s10b=$(TMUX_TMPDIR="$_short" bash -c '
    . "'"$_test_dir"'/_tmux-fixture.sh" >/dev/null 2>&1
    nx_tmux_fixture_init "'"$_deep"'" >/dev/null 2>&1 && echo "root=$NX_TMUX_TMPDIR"' 2>/dev/null)
assert_contains "§10 CONTROL: a SHORT ambient TMUX_TMPDIR is honoured as the root" "$_s10b" "root=$_short/"
rm -rf "$_short" "$_s10w" 2>/dev/null || true

# EXPECTED-COUNT GUARD. A green over fewer assertions than were written is a
# green that covers nothing; this is the mechanism that says so.
#   §1a 3 · §1b 4 · §2 1 · §3 2 · §4 1 · §5 8 · §6 5 · §7 4 · §8 7 · §9 4 · §10 4
EXPECTED=$(( 3 + 4 + 1 + 2 + 1 + 8 + 5 + 4 + 7 + 4 + 4 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

printf '=== host under test: %s, kernel %s ===\n' "$TMUXV" "$KERNEL"
th_summary_and_exit
