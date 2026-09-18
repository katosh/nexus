#!/usr/bin/env bash
# _gh_stub.sh — a `gh` test double that ANSWERS AS MUCH AS THE REAL CLIENT DOES
# (your-org/nexus-code#932, #1125).
#
# Run nothing here; this file is sourced by suites:
#
#     . "$_test_dir/_gh_stub.sh"
#     ghs_make_stub "$WORK/bin/gh" "$WORK/gh-calls.txt" --state-dir "$WORK/ghstate" <<'CASES'
#         */pulls/*)  ghs_emit <<< '{"base":{"ref":"dev"}}' ;;
#         *)          ghs_emit <<< '{}' ;;
#     CASES
#
# ---------------------------------------------------------------------------
# WHY A SECOND STUB BUILDER EXISTS
# ---------------------------------------------------------------------------
#
# `_test_helpers.sh:make_gh_stub` is the shared builder and 11 suites use it.
# It answers LESS than `gh` does, on two axes, and each axis has a filed defect:
#
#   #932  IT IGNORES `--jq`. It CAPTURES the expression into `jq_expr` — so a
#         case arm can DISCRIMINATE two callers of one endpoint — and never
#         APPLIES it. The repo's run/job SELECTION lives entirely inside those
#         expressions, so a stub that returns pre-digested output is blind to
#         the layer the defect lives in. Measured: restoring `.[0:8]` to
#         `_merge_ref_base.sh`'s runs `--jq` — byte-for-byte the diff that
#         shipped as `#882` — left 95 assertions green.
#
#   #1125 ITS WRITE ARMS RETURN NO BODY, AND IT HAS NO STATE. Both halves are
#         needed and only the first is in the issue title. Echoing the request
#         back makes a PATCH's RESPONSE inspectable; it does not make "did the
#         write LAND?" decidable, because #1118's failure — accept, rc 0, print
#         a URL, change nothing — produces a perfectly well-formed response.
#         Only a subsequent READ can tell the two apart, and a stateless stub
#         serves the same canned body to that read either way. So the property
#         "a read-back post-condition can FAIL" requires the stub to REMEMBER.
#
# `make_gh_stub` NOW DELEGATES HERE (your-org/nexus-code#932, W2-22), in one
# line, with `--no-autostate`: its callers get this walker (including `--jq=`
# and the jq-absent refusal) and may call `ghs_emit` from an arm, while the
# state layer stays OFF for them by construction — so the 10 pre-digesting
# callers keep exactly the behaviour they had. A suite that wants the state
# layer calls `ghs_make_stub` directly.
#
# ---------------------------------------------------------------------------
# WHAT THE GENERATED STUB GIVES A CASE ARM
# ---------------------------------------------------------------------------
#
#   $method        the -X verb, default GET
#   $endpoint      the bare /path positional
#   $jq_expr       the caller's --jq expression, or ""
#   $GHS_BODY      the request body (from --input - or --input FILE), or ""
#   ghs_emit       filter: applies $jq_expr with REAL jq when one was passed,
#                  otherwise passes bytes through. USE IT FOR EVERY JSON ARM.
#   ghs_record     store a body against the current endpoint
#   ghs_stored     print the stored body for the current endpoint, if any
#
# ---------------------------------------------------------------------------
# THE THREE MODES, and the negative control is a MODE rather than a fixture
# ---------------------------------------------------------------------------
#
# Set at CALL time in the environment of the process under test, so one stub
# serves all three and the only variable between arms is the mode:
#
#   GHS_MODE unset / =honest
#       A write verb (PATCH/POST/PUT) RECORDS the request body against the
#       endpoint and echoes it back, the way the API does; a DELETE REMOVES
#       the record and answers with an empty body (the API's 204). A later GET
#       on that endpoint serves the RECORDED body, or falls through to the
#       CASES once the record is gone. A read-back post-condition PASSES.
#
#       A WRITE WITH NO BODY RECORDS NOTHING (your-org/nexus-code#1125, the
#       empty-record defect). `-f`/`-F` field writes are consumed by the argv
#       walker and never reach $GHS_BODY, and a DELETE carries no body; either
#       used to write a 0-byte record that a presence-gated `ghs_stored` then
#       served — so every later GET on that endpoint answered EMPTY at rc 0.
#       An empty representation is not a representation; the store keeps
#       only non-empty bodies and reads only non-empty records.
#
#   GHS_MODE=swallow
#       THE #1118 FAILURE, reproduced. The write (any of PATCH/POST/PUT/DELETE)
#       is ACCEPTED — rc 0, and the response is the OLD body, which is what a
#       swallowed PATCH returns — and NOTHING IS RECORDED or removed. A later GET serves the OLD body. A read-back
#       post-condition must FAIL CLOSED here. This is the control that makes
#       the honest mode's pass mean something: a check never observed to fail
#       is not evidence.
#
#   GHS_MODE=swallow-echo
#       The NASTIER swallow, and the reason `swallow` alone is not enough. The
#       write is accepted, nothing is recorded, and the response ECHOES THE
#       REQUEST — so the PATCH's own response is indistinguishable from a
#       successful one, byte for byte. A verb that "verifies" its write by
#       reading its own PATCH response passes here and is still broken. Only a
#       SEPARATE GET separates them. If your read-back check passes under this
#       mode, it is reading the wrong thing.
#
# GHS_SWALLOW_ENDPOINT="<glob>" narrows either swallow mode to endpoints
# matching the glob, so a suite can swallow ONE write in a sequence and assert
# the others still land. Default `*`.
#
# ---------------------------------------------------------------------------
# WHAT THIS DOES NOT DO, stated because an unstated boundary reads as coverage
# ---------------------------------------------------------------------------
#
# * It is not a GitHub API model. The store is keyed on the ENDPOINT STRING, so
#   two spellings of one resource (`?per_page=100` present or absent) are two
#   keys. That is a faithful hazard to expose — a verb that writes one spelling
#   and reads another IS broken — but it means "no stored body" can mean
#   "written under a different key", and a suite asserting an absence must pin
#   the exact spelling.
# * `--paginate` is consumed and ignored; the stub serves one page.
# * `jq` must be on PATH. If it is not, the stub REFUSES loudly (rc 3 and a
#   diagnostic) rather than falling through to `cat` — falling through would
#   silently restore exactly the pre-digested behaviour #932 is about, and the
#   suite would go green for the reason the guard exists to catch.
# * AND A jq FAILURE IS AS LOUD AS A jq ABSENCE (your-org/nexus-code#932 /
#   #1125's residual). `ghs_emit` used to refuse only when jq was ABSENT and
#   stay silent when jq FAILED: a non-JSON arm behind `--jq` answered
#   `stdout=[] rc=0` (jq's parse error went to stderr, which production call
#   sites discard) — a confident empty answer, the dominant defect class,
#   injected by the fix for a member of it. `ghs_emit` now parses its input
#   with jq FIRST and, on any jq failure, prints a diagnostic and signals the
#   stub's TOP LEVEL (it runs in a pipeline subshell, whose own exit cannot
#   reach the stub's status), which exits 3. Measured: the verb sees rc 3 and
#   an empty stdout on both the CASES route and the stored-body route.

# bash 5.2's patsub_replacement makes `&` in a ${var//pat/rep} replacement
# expand to the matched text, which corrupts every case body containing `&&`
# or `>&2` into a syntactically broken stub. Same reason and same remedy as
# _test_helpers.sh; stated here too because this file is sourceable alone.
#
# ambient-shell-option-scope: allow-unconditional-unset  this neutralises a
# bash 5.2 INTERPRETER DEFAULT for every suite that sources this file — it is
# not restoring an option some caller turned on, so there is no caller state to
# hand back wrongly.
shopt -u patsub_replacement 2>/dev/null || true

# ghs_make_stub <stub-path> <capture-path> [--state-dir <dir>]
#                                          [--with-body-capture <path>]
#                                          [--no-autostate]
#
# <capture-path>  every argv line is APPENDED here, as make_gh_stub does, so
#                 existing "the verb called gh with X" assertions port over.
# --state-dir     where recorded write bodies live. Defaults to
#                 "<capture-path>.ghstate". Created lazily by the stub.
# --with-body-capture  additionally write the LAST request body to <path>.
#                 Unlike make_gh_stub's flag this is not what makes the body
#                 available to a case arm — $GHS_BODY always is — it is for
#                 suites that assert on the body from OUTSIDE the stub.
# --no-autostate  the state layer is OFF in the generated stub (the CASES are
#                 the whole dispatch), pinned in the file rather than left to
#                 GHS_NO_AUTOSTATE in the environment. What `make_gh_stub`
#                 passes when it delegates here.
ghs_make_stub() {
    local stub_path="$1" capture_path="$2"; shift 2
    local state_dir="" body_capture="" no_autostate=0
    while (( $# > 0 )); do
        case "$1" in
            --state-dir)         state_dir="$2"; shift 2 ;;
            --with-body-capture) body_capture="$2"; shift 2 ;;
            # The raw case dispatch, by CONSTRUCTION rather than by an
            # environment variable a caller might forget: this is what
            # `make_gh_stub`'s delegation passes, so its 10 inert callers keep
            # exactly the behaviour they had (#932's "behaviour-preserving").
            --no-autostate)      no_autostate=1; shift ;;
            *)
                printf 'ghs_make_stub: unknown flag %q\n' "$1" >&2
                return 2
                ;;
        esac
    done
    [[ -n "$state_dir" ]] || state_dir="${capture_path}.ghstate"

    local cases_body
    cases_body=$(cat)

    # A quoted-literal limiter keeps every $ and backslash in the template;
    # placeholders are substituted afterward.
    local template
    template=$(cat <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> @@CAPTURE@@
if [[ "${1:-}" != "api" ]]; then exit 0; fi
shift

method="GET"
endpoint=""
jq_expr=""
input_arg=""
while (( $# > 0 )); do
    case "$1" in
        -X)            method="$2"; shift 2 ;;
        --jq)          jq_expr="$2"; shift 2 ;;
        --jq=*)        jq_expr="${1#--jq=}"; shift ;;
        --input)       input_arg="$2"; shift 2 ;;
        --input=*)     input_arg="${1#--input=}"; shift ;;
        -H|-f|-F)      shift 2 ;;
        --paginate)    shift ;;
        --)            shift; break ;;
        /*)            endpoint="$1"; shift ;;
        -*)            shift ;;
        *)             shift ;;
    esac
done

# THE REFUSAL, AND IT IS HERE AND NOT ONLY INSIDE `ghs_emit` FOR A MEASURED
# REASON. `ghs_emit` runs on the right-hand side of a pipeline, so its `exit 3`
# kills the SUBSHELL and the stub's own status comes from the `exit 0` below —
# the pipeline-status trap, inside the guard written to prevent a silent
# answer. Checked at the TOP LEVEL, before any pipeline exists.
if [ -n "$jq_expr" ] && ! command -v jq >/dev/null 2>&1; then
    printf 'gh-stub: --jq %s was passed but jq is not on PATH; refusing to answer unfiltered\n' \
        "$jq_expr" >&2
    exit 3
fi

# your-org/nexus-code#921: whether a body is coming is a property of the VERB,
# not of what stdin happens to be attached to. `[ -t 0 ]` was the wrong proxy —
# a GET with no piped body inherits the SUITE's stdin and blocks forever when
# that is an open pipe, so whether a suite hung depended on how it was invoked.
GHS_BODY=""
if [ "$input_arg" = "-" ]; then
    GHS_BODY=$(cat) || true
elif [ -n "$input_arg" ] && [ -r "$input_arg" ]; then
    GHS_BODY=$(cat -- "$input_arg") || true
fi
@@BODYCAP@@

GHS_STATE_DIR=@@STATEDIR@@
@@NOAUTOSTATE@@
# The loud-failure channel for `ghs_emit`, which runs in a pipeline subshell
# and cannot set this process's exit status by itself: it signals THIS pid,
# and the trap turns the signal into the same rc 3 the jq-absent refusal uses.
GHS_TOP_PID=$$
trap 'exit 3' TERM

# Endpoint -> filename: a FULL HEX DUMP of every byte. Injective by
# construction, so two endpoints can never share a record; NOT human-readable
# — decode with `xxd -r -p` when debugging a fixture directory. (This comment
# once described a readable `_XX`-per-non-alnum scheme that was never
# implemented; the injectivity claim held, the readability rationale did not
# — your-org/nexus-code#1125.)
_ghs_key() {
    printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

# ghs_record <body> — store a NON-EMPTY body against the current endpoint.
# An empty body records NOTHING (#1125): a `-f`/`-F` field write or a DELETE
# reaches here with $GHS_BODY="", and a 0-byte record served by a later GET
# is the empty-at-rc-0 answer this library exists to make impossible.
ghs_record() {
    [ -n "${1:-}" ] || return 0
    mkdir -p "$GHS_STATE_DIR" 2>/dev/null || true
    printf '%s' "$1" > "$GHS_STATE_DIR/$(_ghs_key "$endpoint")"
}

# ghs_forget — remove the record for the current endpoint (a DELETE).
ghs_forget() {
    rm -f "$GHS_STATE_DIR/$(_ghs_key "$endpoint")" 2>/dev/null || true
}

# ghs_stored — print the stored body, if there is a NON-EMPTY one. `-s`, not
# `-r`: a presence test passed a 0-byte file and served nothing at rc 0.
ghs_stored() {
    local f="$GHS_STATE_DIR/$(_ghs_key "$endpoint")"
    [ -s "$f" ] || return 1
    cat "$f"
}

# THE FILTER. Every JSON-emitting arm must go through this, or the arm is
# blind to the caller's selection logic — your-org/nexus-code#932's whole
# subject. It REFUSES rather than degrading to `cat` when jq is missing: a
# silent fallback restores the pre-digested behaviour the guard exists to
# catch, and the suite would go green for that exact reason.
ghs_emit() {
    if [ -n "$jq_expr" ]; then
        # Defence in depth only — the reachable refusal is the top-level one
        # above. This arm cannot be the guard: it runs in a pipeline subshell.
        command -v jq >/dev/null 2>&1 || exit 3
        # A jq FAILURE IS LOUD (#932/#1125 residual). The input is parsed
        # FIRST; then the expression runs; either failing prints a diagnostic
        # and signals the stub's top level — `kill` reaches the parent from
        # inside this pipeline subshell, and the parent's TERM trap turns it
        # into exit 3, so the caller can never read a silent empty answer.
        local _ghs_in _ghs_out _ghs_err
        _ghs_in=$(cat)
        if ! printf '%s' "$_ghs_in" | jq . >/dev/null 2>&1; then
            printf 'gh-stub: --jq %s was passed but the arm served NON-JSON (%d bytes); refusing to answer empty (your-org/nexus-code#932)\n' \
                "$jq_expr" "${#_ghs_in}" >&2
            kill -s TERM "$GHS_TOP_PID" 2>/dev/null; exit 3
        fi
        _ghs_err=$(mktemp "${TMPDIR:-/tmp}/ghs-jqerr.XXXXXX" 2>/dev/null || printf '/dev/null')
        if ! _ghs_out=$(printf '%s' "$_ghs_in" | jq -r "$jq_expr" 2>"$_ghs_err"); then
            printf 'gh-stub: --jq %s FAILED on the arm output: %s; refusing to answer empty (your-org/nexus-code#932)\n' \
                "$jq_expr" "$(head -c 200 "$_ghs_err" 2>/dev/null)" >&2
            rm -f "$_ghs_err" 2>/dev/null; kill -s TERM "$GHS_TOP_PID" 2>/dev/null; exit 3
        fi
        rm -f "$_ghs_err" 2>/dev/null
        printf '%s\n' "$_ghs_out"
    else
        cat
    fi
}

_ghs_is_write() {
    case "$method" in PATCH|POST|PUT|DELETE) return 0 ;; *) return 1 ;; esac
}

_ghs_swallowed() {
    case "${GHS_MODE:-honest}" in
        swallow|swallow-echo) ;;
        *) return 1 ;;
    esac
    # shellcheck disable=SC2254 — the glob is the point
    case "$endpoint" in ${GHS_SWALLOW_ENDPOINT:-*}) return 0 ;; *) return 1 ;; esac
}

# ---- the state layer, ahead of the caller's CASES ------------------------
#
# ARM ORDER IS THE DESIGN, not an accident (your-org/nexus-code#1121). The
# write/read-back arms come FIRST because they are the ones a permissive
# catch-all `*)` in the caller's CASES would shadow — and a caller's `*)` is
# exactly what every stub in this repo ends with. Put the CASES first and the
# `#1125` behaviour is unreachable for every suite that has a default arm,
# which is all of them.
#
# GHS_NO_AUTOSTATE=1 opts out per invocation for a suite that wants the raw
# case dispatch back.
if [ -z "${GHS_NO_AUTOSTATE:-}" ] && _ghs_is_write; then
    if _ghs_swallowed; then
        # ACCEPTED, RECORDED NOWHERE. rc 0, a well-formed response: #1118.
        if [ "${GHS_MODE}" = "swallow-echo" ]; then
            printf '%s' "$GHS_BODY" | ghs_emit
            exit 0
        fi
        # Plain `swallow`: answer with the resource as it STANDS — a previously
        # recorded body if there is one, otherwise the caller's own CASES arm,
        # which is the fixture's OLD representation. Falling through rather
        # than inventing `{}` matters: a `{}` is a THIRD outcome a read-back
        # could distinguish for the wrong reason, and the control has to be
        # "the old value came back", not "something odd came back".
        if _stored=$(ghs_stored); then
            printf '%s' "$_stored" | ghs_emit
            exit 0
        fi
    elif [ "$method" = "DELETE" ]; then
        # A DELETE REMOVES the record and answers with no body (the API's
        # 204). Writing the (empty) request body here was the #1125
        # empty-record poisoning: every later GET served a 0-byte file.
        ghs_forget
        exit 0
    else
        ghs_record "$GHS_BODY"
        printf '%s' "$GHS_BODY" | ghs_emit
        exit 0
    fi
fi

if [ -z "${GHS_NO_AUTOSTATE:-}" ] && [ "$method" = "GET" ]; then
    if _stored=$(ghs_stored); then
        printf '%s' "$_stored" | ghs_emit
        exit 0
    fi
fi

case "$endpoint" in
@@CASES@@
esac
exit 0
STUB
)

    local body_cap_block=""
    if [[ -n "$body_capture" ]]; then
        body_cap_block=$(printf 'printf %%s "$GHS_BODY" > %q 2>/dev/null || true' "$body_capture")
    else
        body_cap_block=':'
    fi

    local capture_quoted state_quoted
    capture_quoted=$(printf '%q' "$capture_path")
    state_quoted=$(printf '%q' "$state_dir")

    local autostate_block=':'
    (( no_autostate )) && autostate_block='GHS_NO_AUTOSTATE=1'

    template=${template//@@CAPTURE@@/$capture_quoted}
    template=${template//@@STATEDIR@@/$state_quoted}
    template=${template//@@NOAUTOSTATE@@/$autostate_block}
    template=${template//@@BODYCAP@@/$body_cap_block}
    template=${template//@@CASES@@/$cases_body}

    mkdir -p "$(dirname "$stub_path")"
    printf '%s\n' "$template" > "$stub_path"
    chmod +x "$stub_path"
}
