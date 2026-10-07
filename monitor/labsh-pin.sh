#!/usr/bin/env bash
# labsh-pin.sh — the labsh SERVER-env pin (your-org/nexus-code#1676).
# Rationale, file layout and the shim: monitor/_labsh_pin.sh.
#
#   labsh-pin.sh status     [PROJECT_DIR]   what is pinned, and whether it applies
#   labsh-pin.sh capture    [PROJECT_DIR]   freeze the RUNNING, healthy server's env
#                                           (with no shim-recorded spec yet — a
#                                           server started by pre-#1677 code —
#                                           the spec is read from the running
#                                           build process's own argv)
#   labsh-pin.sh refresh    [PROJECT_DIR]   build the current resolution in the
#                                           background, smoke-test it, swap the pin
#   labsh-pin.sh quarantine [PROJECT_DIR]   move a pin aside after a start that
#                                           failed while resolving against it
#   labsh-pin.sh demote     [PROJECT_DIR]   the last start WAS pinned, resolved,
#                                           and still failed its healthcheck (the
#                                           supervisor calls this after 2 in a
#                                           row): roll back to .prev, else
#                                           quarantine — never restart the same
#                                           pinned env forever
#
# PROJECT_DIR defaults to $PWD (the labsh project, i.e. the registry workdir).
#
# Exit codes:
#   0  done (including "nothing to do": already pinned / already current)
#   1  failed (the step that failed is named on stderr)
#   2  usage
#   3  REFUSED — a precondition is not established (no healthy server to
#      capture from, no recorded spec to refresh from, a smoke test that did
#      not pass). Nothing was changed.
#   4  busy — another capture/refresh holds the lock. Nothing was changed.
#
# Knobs:
#   LABSH_PIN_REFRESH_TIMEOUT  seconds for the candidate build (default 5400;
#       WE CHOSE 1.5 h: a cold build was measured >30 min at load ~100).
#   LABSH_PIN_SMOKE_TIMEOUT    seconds for the candidate server to answer
#       (default 900, the supervisor's START_GRACE).

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_labsh_pin.sh
source "$SCRIPT_DIR/_labsh_pin.sh"
# shellcheck source=_labsh_build_evidence.sh
source "$SCRIPT_DIR/_labsh_build_evidence.sh"

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

verb="${1:-}"; shift || true
case "$verb" in status|capture|refresh|quarantine|demote) ;; -h|--help|'') usage ;; *) usage ;; esac
PROJECT_DIR=$(cd "${1:-$PWD}" 2>/dev/null && pwd) || { echo "labsh-pin: no such project dir: ${1:-$PWD}" >&2; exit 2; }
JDIR="$PROJECT_DIR/.jupyter"
[[ -d "$JDIR" ]] || { echo "labsh-pin: $JDIR does not exist — not a labsh project" >&2; exit 3; }

PIN=$(labsh_pin_file "$JDIR")
SPEC=$(labsh_pin_spec_file "$JDIR")
META="$PIN.meta"
LOG="$JDIR/labsh-pin.log"
LOCK="$JDIR/labsh-pin.lock"

say() { local m; m="[$(date -Is)] labsh-pin $verb: $*"; printf '%s\n' "$m" >&2; printf '%s\n' "$m" >> "$LOG" 2>/dev/null || true; }

meta_get() { sed -n "s/^$1=//p" "$META" 2>/dev/null | tail -1; }
write_meta() {   # write_meta source env
    { printf 'captured_at=%s\n' "$(date +%s)"
      printf 'captured_iso=%s\n' "$(date -Is)"
      printf 'source=%s\n' "$1"
      printf 'env=%s\n' "$2"
      printf 'refreshed_at=%s\n' "$(date +%s)"
    } > "$META.tmp.$$" && mv -f "$META.tmp.$$" "$META"
}
meta_set() {   # meta_set key value — replace/append one key, atomically
    local tmp="$META.tmp.$$"
    { grep -v "^$1=" "$META" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$tmp" && mv -f "$tmp" "$META"
}
touch_refreshed() {
    local tmp="$META.tmp.$$"
    { grep -v '^refreshed_at=' "$META" 2>/dev/null; printf 'refreshed_at=%s\n' "$(date +%s)"; } > "$tmp" && mv -f "$tmp" "$META"
}

# freeze <env-dir> <out-file> — `uv pip freeze` of an env, sorted, to <out>.
freeze() {
    local env="$1" out="$2"
    [[ -f "$env/pyvenv.cfg" && -x "$env/bin/python" ]] || return 1
    uv pip freeze --python "$env/bin/python" 2>/dev/null | LC_ALL=C sort > "$out" || return 1
    grep -q '^jupyterlab==' "$out" || return 1       # a freeze without jupyterlab is not a server env
}

# The env the LIVE server runs from. The build pid labsh recorded is `uv`, proven
# ours by the shared identity gates; its child is the server, and uv prepends
# the env's bin/ to the child's PATH. Only PATH is read from that environ — it
# also carries JUPYTER_TOKEN, which is never printed.
running_env() {
    local pid port c first env
    pid=$(cat "$JDIR/labsh.bg.pid" 2>/dev/null)
    port=$(awk -F= '$1 == "PORT" { print $2; exit }' "$JDIR/labsh-service.env" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    labsh_build_is_ours "$pid" "$PROJECT_DIR" "$port" || return 1
    # uv spawns from a worker THREAD, so the child can be listed under any
    # task's `children` — hence the glob. Expanded into an array and checked,
    # never handed straight to `cat`: under an inherited `nullglob` an
    # unmatched glob VANISHES and a bare `cat` reads stdin (a block, at 0% CPU).
    local -a kids_f=( /proc/"$pid"/task/*/children )
    [[ -e "${kids_f[0]:-}" ]] || return 1
    for c in $(cat -- "${kids_f[@]}" </dev/null 2>/dev/null); do
        first=$( { tr '\0' '\n' < "/proc/$c/environ"; } 2>/dev/null | sed -n 's/^PATH=//p' | cut -d: -f1)
        env="${first%/bin}"
        if [[ -n "$env" && -f "$env/pyvenv.cfg" && -e "$env/bin/jupyter-lab" ]]; then
            printf '%s' "$env"
            return 0
        fi
    done
    return 1
}

# spec_from_running_argv — the uvx arguments labsh passed for the LIVE server,
# read from that server's own build process (your-org/nexus-code#1692). Used
# only when the shim has not recorded a spec yet, which is exactly the state of
# a server started by code that predates the shim: the first restart after the
# pin feature lands. Without it that restart is always UNPINNED, and a single
# upstream release since the server started makes it a cold build — measured on
# the deploy of #1677 itself: charset-normalizer 3.5.1→3.5.2, ~30 min.
# The pid is the one labsh recorded, proven OURS by the shared identity gates
# (uid, exe=uv, cwd=workdir, jupyterlab argv) — never a sibling agent's argv.
# Prints one argument per line, exactly the shape the shim records; fails
# rather than guess.
spec_from_running_argv() {
    local pid port a seen=0
    local -a argv=()
    pid=$(cat "$JDIR/labsh.bg.pid" 2>/dev/null)
    port=$(awk -F= '$1 == "PORT" { print $2; exit }' "$JDIR/labsh-service.env" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    labsh_build_is_ours "$pid" "$PROJECT_DIR" "$port" || return 1
    # Grouped so 2>/dev/null is applied BEFORE the < fails on a vanished pid (#1703).
    { while IFS= read -r -d '' a; do argv+=("$a"); done < "/proc/$pid/cmdline"; } 2>/dev/null
    # `uv tool uvx ARGS… jupyter-lab …` or `uvx ARGS… jupyter-lab …`: emit ARGS.
    local -a out=()
    for a in "${argv[@]}"; do
        if (( ! seen )); then
            [[ "$a" == uvx || "${a##*/}" == uvx ]] && seen=1
            continue
        fi
        [[ "$a" == jupyter-lab ]] && { printf '%s\n' "${out[@]}"; return 0; }
        out+=("$a")
    done
    return 1
}

take_lock() {
    # flock-fd: held for this short-lived verb's whole run on purpose (one
    # capture/refresh at a time). The two LONG-LIVED children it spawns — the
    # candidate build and the smoke-test server — are launched with `9>&-`, so
    # neither can keep the lock alive after this process exits; the rest (uv pip
    # freeze, python -c, curl) are waited-for and end before we do.
    exec 9>>"$LOCK" || { say "cannot open lock $LOCK"; exit 1; }
    flock -n 9 || { say "another capture/refresh holds $LOCK — nothing changed"; exit 4; }
}

cmd_status() {
    local n lab
    if [[ -s "$PIN" ]]; then
        n=$(grep -c '==' "$PIN"); lab=$(sed -n 's/^jupyterlab==//p' "$PIN")
        echo "pin:        $PIN ($n packages, jupyterlab $lab)"
        echo "captured:   $(meta_get captured_iso) from $(meta_get source)"
        echo "refreshed:  $(date -d "@$(meta_get refreshed_at)" -Is 2>/dev/null || echo '?')"
        if [[ -s "$SPEC" ]] && cmp -s "$PIN.spec" "$SPEC"; then
            echo "applies:    yes — the pin was captured under the spec labsh last used"
        elif [[ -s "$SPEC" ]]; then
            echo "applies:    NO — labsh's uvx spec changed since capture; the next healthy start re-captures"
        else
            echo "applies:    unknown — no spec recorded yet (the shim records it at the next start)"
        fi
    else
        echo "pin:        none — starts resolve UNPINNED (a new release anywhere in the set forces a cold build)"
    fi
    [[ -f "$PIN.bad" ]] && echo "quarantined: $PIN.bad (a start failed while resolving against it)"
    [[ "${LABSH_SVC_PIN:-1}" == 0 ]] && echo "note:       LABSH_SVC_PIN=0 in this environment — the pin is never applied"
    return 0
}

cmd_capture() {
    local env tmp spec_src="$SPEC" derived_f=''

    env=$(running_env) || { say "REFUSED: no running labsh server env found for $PROJECT_DIR (capture only from a live server)"; exit 3; }
    "$SCRIPT_DIR/jupyter-health.sh" "$PROJECT_DIR" >/dev/null 2>&1 \
        || { say "REFUSED: the server is not passing its healthcheck — a pin is only taken from a HEALTHY env"; exit 3; }
    if [[ ! -s "$SPEC" ]]; then
        local derived
        derived=$(spec_from_running_argv) \
            || { say "REFUSED: no recorded uvx spec ($SPEC) and none derivable from the running build's argv"; exit 3; }
        local -a dspec=()
        mapfile -t dspec <<<"$derived"
        labsh_pin_server_split "${dspec[@]}" jupyter-lab >/dev/null \
            || { say "REFUSED: the argv-derived spec is not a labsh server spec — not pinning a guess"; exit 3; }
        # Held in a private temp file and published as $SPEC only once the
        # pin itself is written, so every REFUSED/FAILED/busy exit below leaves
        # the project exactly as it found it — the header's promise (skeptic
        # labshseedsk on #1697: the first cut wrote $SPEC before the lock).
        derived_f="$SPEC.derived.$$"
        printf '%s\n' "$derived" > "$derived_f" || { say "FAILED: could not stage the derived spec"; exit 1; }
        # shellcheck disable=SC2064
        trap "rm -f '$derived_f'" EXIT
        spec_src="$derived_f"
        say "no shim-recorded spec yet (server predates the shim): derived it from the running build's own argv"
    fi
    take_lock
    tmp="$PIN.tmp.$$"
    freeze "$env" "$tmp" || { rm -f "$tmp"; say "FAILED: could not freeze $env"; exit 1; }
    if [[ -s "$PIN" ]] && cmp -s "$tmp" "$PIN" && cmp -s "$PIN.spec" "$spec_src"; then
        rm -f "$tmp"
        return 0                                   # already pinned to exactly this env
    fi
    [[ -s "$PIN" ]] && cp -f "$PIN" "$PIN.prev"
    cp -f "$spec_src" "$PIN.spec.tmp.$$" && mv -f "$PIN.spec.tmp.$$" "$PIN.spec"
    mv -f "$tmp" "$PIN"
    # A derived spec is published only now, beside the pin captured under it.
    [[ -n "$derived_f" ]] && mv -f "$derived_f" "$SPEC"
    write_meta capture "$env"
    say "pinned the running healthy server env ($(grep -c '==' "$PIN") packages, jupyterlab $(sed -n 's/^jupyterlab==//p' "$PIN")) from $env"
}

cmd_quarantine() {
    [[ -s "$PIN" ]] || return 0
    # Only on positive evidence: the last start resolved AGAINST the pin and uv
    # reported a resolution failure, and no build of ours is still running.
    grep -q 'labsh-uvx-shim: resolving against the server-env pin' "$JDIR/labsh.bg.log" 2>/dev/null || return 0
    grep -qE 'No solution found|Because .* we can conclude|unsatisfiable' "$JDIR/labsh.bg.log" 2>/dev/null || return 0
    labsh_build_in_progress "$PROJECT_DIR" >/dev/null 2>&1 && return 0
    take_lock
    mv -f "$PIN" "$PIN.bad"
    say "QUARANTINED $PIN → $PIN.bad: the last start failed to RESOLVE against it (see labsh.bg.log); the next start runs unpinned and re-captures once healthy"
}

cmd_demote() {
    [[ -s "$PIN" ]] || { say "nothing to demote: no pin"; return 0; }
    # Positive evidence only: the LAST start resolved against the pin (labsh
    # rewrites labsh.bg.log on every start, so it describes that start).
    grep -q 'labsh-uvx-shim: resolving against the server-env pin' "$JDIR/labsh.bg.log" 2>/dev/null \
        || { say "the last start was not pinned — nothing to demote"; return 0; }
    labsh_build_in_progress "$PROJECT_DIR" >/dev/null 2>&1 && { say "a build is still in flight — not demoting"; return 0; }
    take_lock
    if [[ -s "$PIN.prev" ]] && ! cmp -s "$PIN.prev" "$PIN"; then
        mv -f "$PIN" "$PIN.bad"
        mv -f "$PIN.prev" "$PIN"
        meta_set source rollback
        say "ROLLED BACK: pinned starts failed their healthcheck; the failing pin is kept at $PIN.bad and the PREVIOUS pin (jupyterlab $(sed -n 's/^jupyterlab==//p' "$PIN")) is restored — it is still in the uv cache, so the next start is warm"
    else
        mv -f "$PIN" "$PIN.bad"
        say "QUARANTINED $PIN → $PIN.bad: pinned starts failed their healthcheck and there is no different previous pin; the next start runs unpinned (possibly COLD) and re-captures once healthy"
    fi
}

cmd_refresh() {
    local -a spec=()
    local real work env tmp out rc port tok sp i ok=0 line
    [[ -s "$SPEC" ]] || { say "REFUSED: no recorded uvx spec ($SPEC) — the shim writes it at the next server start"; exit 3; }
    while IFS= read -r line; do spec+=("$line"); done < "$SPEC"
    real=$(labsh_pin_real_uvx) || { say "FAILED: no real uvx on PATH"; exit 1; }
    take_lock
    work=$(mktemp -d "${TMPDIR:-/tmp}/labsh-pin-refresh.XXXXXX") || { say "FAILED: mktemp"; exit 1; }
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    say "building the CURRENT unconstrained resolution in the background (the pinned env keeps serving; bound ${LABSH_PIN_REFRESH_TIMEOUT:-5400}s)"
    # cwd = $work, never the project: the build-identity gates key on cwd, so
    # no layer can mistake this candidate build for the service's own.
    out="$work/build.out"
    ( cd "$work" && env -u UV_CONSTRAINT nice -n 10 timeout -k 30 "${LABSH_PIN_REFRESH_TIMEOUT:-5400}" \
        "$real" "${spec[@]}" python -c 'import sys, jupyterlab, jupyter_server; print("LABSH_PIN_ENV=" + sys.prefix)' ) \
        > "$out" 2>"$work/build.err" 9>&-
    rc=$?
    if (( rc != 0 )); then
        say "FAILED: candidate build rc=$rc (124/137 = the bound expired); tail: $(tail -3 "$work/build.err" | tr '\n' ' ')"
        meta_set refresh_result "build-failed rc=$rc"
        exit 1
    fi
    env=$(sed -n 's/^LABSH_PIN_ENV=//p' "$out" | tail -1)
    tmp="$work/candidate.pin"
    freeze "$env" "$tmp" || { say "FAILED: could not freeze the candidate env '$env'"; meta_set refresh_result "freeze-failed"; exit 1; }
    if [[ -s "$PIN" ]] && cmp -s "$tmp" "$PIN" && cmp -s "$PIN.spec" "$SPEC"; then
        touch_refreshed
        meta_set refresh_result current
        say "already current: the latest resolution equals the pin (jupyterlab $(sed -n 's/^jupyterlab==//p' "$PIN"))"
        return 0
    fi
    # Smoke test: a throwaway server from the CANDIDATE env, on a free loopback
    # port, with its own config/data/runtime dirs — never the project's, so the
    # live server's state is untouched. setsid ⇒ its own process group, killed
    # by the pid WE started ($!), never by argv.
    port=$("$env/bin/python" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
        || { say "FAILED: could not pick a smoke-test port"; exit 1; }
    tok=$("$env/bin/python" -c 'import secrets; print(secrets.token_hex(16))')
    mkdir -p "$work/cfg" "$work/data" "$work/rt" "$work/root"
    ( cd "$work/root" && JUPYTER_CONFIG_DIR="$work/cfg" JUPYTER_DATA_DIR="$work/data" JUPYTER_RUNTIME_DIR="$work/rt" \
        JUPYTER_TOKEN="$tok" exec setsid "$env/bin/jupyter-lab" --no-browser --ip 127.0.0.1 --port "$port" \
        --ServerApp.port_retries=0 --ServerApp.root_dir="$work/root" ) > "$work/smoke.log" 2>&1 9>&- &
    sp=$!
    for (( i = 0; i < ${LABSH_PIN_SMOKE_TIMEOUT:-900}; i += 2 )); do
        kill -0 "$sp" 2>/dev/null || break
        if curl -fsS -o /dev/null --max-time 5 -H "Authorization: token $tok" "http://127.0.0.1:$port/api/status" \
           && curl -fsS -o /dev/null --max-time 10 -H "Authorization: token $tok" "http://127.0.0.1:$port/lab"; then
            ok=1; break
        fi
        sleep 2
    done
    kill -TERM -- "-$sp" 2>/dev/null || kill -TERM "$sp" 2>/dev/null
    wait "$sp" 2>/dev/null
    if (( ! ok )); then
        say "REFUSED: the candidate env did not serve /api/status and /lab within ${LABSH_PIN_SMOKE_TIMEOUT:-900}s — pin NOT swapped; tail: $(tail -3 "$work/smoke.log" | tr '\n' ' ')"
        meta_set refresh_result smoke-failed
        exit 3
    fi
    [[ -s "$PIN" ]] && cp -f "$PIN" "$PIN.prev"
    cp -f "$SPEC" "$PIN.spec.tmp.$$" && mv -f "$PIN.spec.tmp.$$" "$PIN.spec"
    cp -f "$tmp" "$PIN.tmp.$$" && mv -f "$PIN.tmp.$$" "$PIN"
    write_meta refresh "$env"
    meta_set refresh_result swapped
    say "SWAPPED the pin to the refreshed env (jupyterlab $(sed -n 's/^jupyterlab==//p' "$PIN"); previous kept at $PIN.prev); it is already in the uv cache, so it takes effect WARM at the next server restart"
}

"cmd_$verb"
