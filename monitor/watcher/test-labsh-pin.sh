#!/usr/bin/env bash
# test-labsh-pin.sh — the labsh SERVER-env pin (your-org/nexus-code#1676).
#
# Hermetic: a fake "real" uvx and fake server envs under mktemp; no network, no
# uv cache, no live labsh. What is pinned down:
#
#   shim   labsh's SERVER call (`--from jupyterlab … jupyter-lab`) gets
#          `--constraints <pin>` iff a pin captured under the SAME spec exists;
#          the spec is recorded; every other call passes through untouched; the
#          shim never finds itself as "the real uvx".
#   refresh  builds the candidate from the RECORDED spec, UNconstrained; swaps
#          the pin only after a throwaway server from the candidate env answers
#          /api/status and /lab; a candidate that does not serve leaves the pin
#          untouched (rc 3); an unchanged resolution is "already current".
#   quarantine  moves a pin aside only on positive evidence that a start failed
#          to RESOLVE against it.
#   capture  refuses (rc 3) without a live server — it never pins a guess.
#
# Run: bash monitor/watcher/test-labsh-pin.sh

set -uo pipefail
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_mon=$(cd "$_here/.." && pwd)
# THE SUBJECTS — the one list both the population declaration and the body
# below use, so `gp_population` CALLS what the suite exercises rather than
# restating it (guard-populations.manifest, kind `inline`).
_subjects() {
    printf '%s\n' monitor/labsh-pin.sh monitor/_labsh_pin.sh \
        monitor/labsh-uvx-shim/uvx monitor/labsh-uvx-shim/bash_env.sh \
        monitor/labsh-supervised.sh monitor/_labsh_build_evidence.sh \
        monitor/svc.sh
}
_subject() { _subjects | grep -xF -- "monitor/$1" | sed "s|^monitor/|$_mon/|"; }
# shellcheck disable=SC1091
. "$_mon/_guard_population.sh"
gp_population() { _subjects; }
gp_handle "$@"
# shellcheck source=_test_helpers.sh
. "$_here/_test_helpers.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/labsh-pin-test.XXXXXX") || exit 1
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ── HERMETICITY, and a CANARY for when it fails ────────────────────────────
# The nexus BASH_ENV prelude re-fronts locals/bin in every non-interactive bash.
# Left set, it SHADOWS the fake uvx below with the REAL one — which is exactly
# how this suite's first draft ran a real `uvx --from jupyterlab` against the
# live uv cache for ~4.5 min (2026-09-29). Unset it; and should anything still
# reach a real uv, UV_OFFLINE + an empty throwaway cache make it fail in
# seconds instead of materialising an environment.
unset BASH_ENV ZDOTDIR NEXUS_PREV_BASH_ENV
export UV_OFFLINE=1 UV_CACHE_DIR="$WORK/uv-canary-cache" UV_NO_CONFIG=1

SHIM=$(_subject labsh-uvx-shim/uvx)
PIN_TOOL=$(_subject labsh-pin.sh)
SUPERVISOR=$(_subject labsh-supervised.sh)
SVC=$(_subject svc.sh)
[[ -x "$SHIM" && -x "$PIN_TOOL" && -r "$SUPERVISOR" ]] || { echo "FIXTURE BROKEN: a subject is missing" >&2; exit 1; }
UV_BIN=$(command -v uv 2>/dev/null || true)
# `uv pip freeze` refuses Python < 3.8 and this host's python3 is 3.6.9, so the
# fake envs borrow a uv-MANAGED interpreter — found offline, never downloaded.
FAKE_PY=''
[[ -n "$UV_BIN" ]] && FAKE_PY=$(uv python find --no-python-downloads '>=3.8' 2>/dev/null) || FAKE_PY=''
export FAKE_PY

# ---- a fake "real" uvx ------------------------------------------------------
# Records its argv. For a `python -c …` command (what refresh runs) it builds a
# fake server env whose jupyterlab version is $FAKE_LAB_VERSION and prints the
# LABSH_PIN_ENV= line the real command would print.
REALDIR="$WORK/realbin"; mkdir -p "$REALDIR"
ARGV_LOG="$WORK/uvx-argv.log"
cat > "$REALDIR/uvx" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
for a in "\$@"; do
    if [[ "\$a" == python ]]; then
        env="$WORK/envs/lab-\${FAKE_LAB_VERSION:-4.0.0}"
        "$WORK/mkenv.sh" "\$env" "\${FAKE_LAB_VERSION:-4.0.0}" "\${FAKE_LAB_BROKEN:-0}"
        echo "LABSH_PIN_ENV=\$env"
        exit 0
    fi
done
exit 0
EOF
chmod +x "$REALDIR/uvx"

# A fake venv: pyvenv.cfg, python → the host python3, one dist-info so
# `uv pip freeze` reports `jupyterlab==<v>`, and a jupyter-lab that serves
# /api/status and /lab (or dies at once when BROKEN=1).
cat > "$WORK/mkenv.sh" <<'EOF'
#!/usr/bin/env bash
env="$1" ver="$2" broken="$3"
py="${FAKE_PY:?FAKE_PY unset}"
pyv=$("$py" -c 'import sys; print("python%d.%d" % sys.version_info[:2])')
sp="$env/lib/$pyv/site-packages"
mkdir -p "$env/bin" "$sp/jupyterlab-$ver.dist-info"
printf 'home = %s\ninclude-system-site-packages = false\nversion = 3\n' "$(dirname "$py")" > "$env/pyvenv.cfg"
ln -sf "$py" "$env/bin/python"
printf 'Metadata-Version: 2.1\nName: jupyterlab\nVersion: %s\n' "$ver" > "$sp/jupyterlab-$ver.dist-info/METADATA"
printf 'uv\n' > "$sp/jupyterlab-$ver.dist-info/INSTALLER"
: > "$sp/jupyterlab-$ver.dist-info/RECORD"
if [[ "$broken" == 1 ]]; then
    printf '#!/bin/sh\necho "fake jupyter-lab: ImportError" >&2\nexit 1\n' > "$env/bin/jupyter-lab"
else
    cat > "$env/bin/jupyter-lab" <<'PY'
#!/usr/bin/env python3
import sys, http.server
port = int(sys.argv[sys.argv.index("--port") + 1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path.split("?")[0] in ("/api/status", "/lab")
        self.send_response(200 if ok else 404); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
fi
chmod +x "$env/bin/jupyter-lab"
EOF
chmod +x "$WORK/mkenv.sh"

PROJ="$WORK/proj"; JD="$PROJ/.jupyter"; mkdir -p "$JD"
BASEPATH="$REALDIR:$PATH"
SHIMPATH="$(dirname "$SHIM"):$BASEPATH"
SERVER_ARGS=(--python 3.12 --from jupyterlab --with jupyterlmod jupyter-lab --port 9999 --no-browser)

echo "## shim: the real uvx is found PAST the shim, never the shim itself"
: > "$ARGV_LOG"
PATH="$SHIMPATH" LABSH_PIN_DIR="$JD" "$SHIM" --version >/dev/null 2>&1
assert_eq "a non-server call passes through untouched" "$(cat "$ARGV_LOG")" "--version"
# PATH = the shim dir + system dirs that hold NO uvx: the shim must refuse
# (127, its own message) rather than find and exec ITSELF in a loop.
PATH="$(dirname "$SHIM"):/usr/bin:/bin" /bin/bash "$SHIM" --version >/dev/null 2>"$WORK/err"; rc=$?
assert_rc "with no real uvx past the shim it refuses (127) instead of exec'ing itself" "$rc" "127"
assert_contains "…with its own diagnostic" "$(cat "$WORK/err")" "no real uvx on PATH"

echo "## shim: the server call records its spec; no pin ⇒ unpinned"
: > "$ARGV_LOG"
PATH="$SHIMPATH" LABSH_PIN_DIR="$JD" "$SHIM" "${SERVER_ARGS[@]}" 2>"$WORK/err"
assert_eq "spec = the args before jupyter-lab" "$(tr '\n' ' ' < "$JD/labsh-server.spec")" "--python 3.12 --from jupyterlab --with jupyterlmod "
assert_not_contains "no pin ⇒ no --constraints" "$(cat "$ARGV_LOG")" "--constraints"
assert_contains "…and it says so (into labsh.bg.log in production)" "$(cat "$WORK/err")" "starting UNPINNED"
assert_not_contains "the shim's message carries no URL (a URL in bg.log means 'bound')" "$(cat "$WORK/err")" "http"

echo "## shim: a pin captured under the SAME spec is applied"
printf 'jupyterlab==4.0.0\n' > "$JD/labsh-server.pin"
cp "$JD/labsh-server.spec" "$JD/labsh-server.pin.spec"
: > "$ARGV_LOG"
PATH="$SHIMPATH" LABSH_PIN_DIR="$JD" "$SHIM" "${SERVER_ARGS[@]}" 2>/dev/null
assert_eq "pinned ⇒ --constraints <pin> ahead of labsh's own args" \
    "$(cat "$ARGV_LOG")" "--constraints $JD/labsh-server.pin ${SERVER_ARGS[*]}"

echo "## shim: a changed spec, or LABSH_SVC_PIN=0, is NOT pinned"
: > "$ARGV_LOG"
PATH="$SHIMPATH" LABSH_PIN_DIR="$JD" "$SHIM" --python 3.12 --from jupyterlab --with NEWPKG jupyter-lab --port 9999 2>"$WORK/err"
assert_not_contains "spec changed ⇒ unpinned (a pin for another set could be unsatisfiable)" "$(cat "$ARGV_LOG")" "--constraints"
assert_contains "…and it says why" "$(cat "$WORK/err")" "spec changed"
PATH="$SHIMPATH" LABSH_PIN_DIR="$JD" "$SHIM" "${SERVER_ARGS[@]}" >/dev/null 2>&1   # restore the spec
: > "$ARGV_LOG"
PATH="$SHIMPATH" LABSH_PIN_DIR="$JD" LABSH_SVC_PIN=0 "$SHIM" "${SERVER_ARGS[@]}" 2>/dev/null
assert_not_contains "LABSH_SVC_PIN=0 ⇒ unpinned" "$(cat "$ARGV_LOG")" "--constraints"
: > "$ARGV_LOG"
PATH="$SHIMPATH" "$SHIM" "${SERVER_ARGS[@]}" 2>/dev/null
assert_not_contains "no LABSH_PIN_DIR (not under the supervisor) ⇒ pure pass-through" "$(cat "$ARGV_LOG")" "--constraints"

echo "## #1676: under the nexus BASH_ENV prelude, labsh's uvx reaches the SHIM — and nothing else moves"
# The prelude re-fronts locals/bin in every non-interactive bash, and labsh is
# bash: a plain `labsh start` resolves uvx to locals/bin/uvx (the NEGATIVE
# control below), so the shim would be inert. `labsh_start_pinned` (lifted
# verbatim from the supervisor) chains the prelude and fronts only the shim.
# The orchestrator's condition: the server uvx must see the pin AND the same
# UV_CACHE_DIR, the helper install's `uv` must resolve where it did, and the
# server tree must get the ORIGINAL BASH_ENV back.
FLOC="$WORK/fake-locals/bin"; mkdir -p "$FLOC"
VIEW="$WORK/labsh-view"; SERVER_SEEN="$WORK/server-seen"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FLOC/uv"
cat > "$FLOC/uvx" <<EOF
#!/usr/bin/env bash
{ echo "argv=\$*"; echo "UV_CACHE_DIR=\${UV_CACHE_DIR:-}"; echo "BASH_ENV=\${BASH_ENV:-}"; } > "$SERVER_SEEN"
EOF
cat > "$FLOC/labsh" <<EOF
#!/usr/bin/env bash
{ echo "uv=\$(command -v uv)"; echo "uvx=\$(command -v uvx)"; } > "$VIEW"
uvx ${SERVER_ARGS[*]}
EOF
chmod +x "$FLOC/uv" "$FLOC/uvx" "$FLOC/labsh"
PRELUDE="$WORK/fake-prelude.sh"
printf 'PATH="%s:${PATH}"; export PATH\n' "$FLOC" > "$PRELUDE"
printf 'jupyterlab==4.0.0\n' > "$JD/labsh-server.pin"
cp "$JD/labsh-server.spec" "$JD/labsh-server.pin.spec"
PIN_SHIM_DIR="$(dirname "$SHIM")"
eval "$(sed -n '/^labsh_start_pinned() {/,/^}/p' "$SUPERVISOR")"
declare -F labsh_start_pinned >/dev/null || { echo "could not lift labsh_start_pinned from the supervisor" >&2; exit 1; }
# The CALLER's PATH must resolve `labsh` to the fake too — the supervisor's has
# locals/bin up front. The first draft left it off, and the test shell ran the
# operator's REAL labsh (its uvx landed on the recorder, so nothing was built).
# Asserted, so that cannot recur silently.
_labsh_seen=$(PATH="$FLOC:$BASEPATH" bash -c 'command -v labsh')
[[ "$_labsh_seen" == "$FLOC/labsh" ]] || { echo "FIXTURE BROKEN: labsh resolves to '$_labsh_seen', not the fake — refusing to run a real labsh" >&2; exit 1; }
rm -f "$VIEW" "$SERVER_SEEN"
( export PATH="$FLOC:$BASEPATH" BASH_ENV="$PRELUDE" UV_CACHE_DIR="/persistent/locals/uv/cache" LABSH_PIN_DIR="$JD"
  cd "$PROJ" && labsh_start_pinned --port 9999 ) >/dev/null 2>&1
assert_eq "inside labsh, uvx resolves to the SHIM" "$(sed -n 's/^uvx=//p' "$VIEW")" "$SHIM"
assert_eq "inside labsh, uv (the helper-venv install's tool) resolves where it did" "$(sed -n 's/^uv=//p' "$VIEW")" "$FLOC/uv"
assert_contains "the server uvx got the pin" "$(cat "$SERVER_SEEN")" "argv=--constraints $JD/labsh-server.pin"
assert_contains "…and the SAME persistent uv cache" "$(cat "$SERVER_SEEN")" "UV_CACHE_DIR=/persistent/locals/uv/cache"
assert_contains "…and the ORIGINAL BASH_ENV, handed back by the shim" "$(cat "$SERVER_SEEN")" "BASH_ENV=$PRELUDE"
# NEGATIVE CONTROL: the same PATH, a plain `labsh start` under the prelude.
rm -f "$VIEW" "$SERVER_SEEN"
( export PATH="$PIN_SHIM_DIR:$FLOC:$BASEPATH" BASH_ENV="$PRELUDE" LABSH_PIN_DIR="$JD"
  cd "$PROJ" && labsh start --port 9999 ) >/dev/null 2>&1
assert_eq "CONTROL: without the chain, the prelude SHADOWS the shim (why the chain exists)" \
    "$(sed -n 's/^uvx=//p' "$VIEW")" "$FLOC/uvx"
assert_not_contains "CONTROL: …and the server uvx gets no pin" "$(cat "$SERVER_SEEN")" "--constraints"

echo "## capture refuses without a live server (never pins a guess)"
PATH="$BASEPATH" "$PIN_TOOL" capture "$PROJ" >/dev/null 2>&1; rc=$?
assert_rc "capture with no running server ⇒ REFUSED rc 3" "$rc" "3"

REFRESH_RAN=0
if [[ -z "$UV_BIN" || -z "$FAKE_PY" ]]; then
    th_skip "refresh cases: no \`uv\` on PATH, or no uv-managed Python >= 3.8 to build the fake envs on"
else
    REFRESH_RAN=1
    echo "## refresh: the current resolution differs and SERVES ⇒ pin swapped, previous kept"
    : > "$ARGV_LOG"
    printf 'jupyterlab==4.0.0\n' > "$JD/labsh-server.pin"
    cp "$JD/labsh-server.spec" "$JD/labsh-server.pin.spec"
    PATH="$SHIMPATH" LABSH_PIN_DIR="$JD" UV_CONSTRAINT=/nonexistent FAKE_LAB_VERSION=4.1.0 \
        LABSH_PIN_SMOKE_TIMEOUT=60 "$PIN_TOOL" refresh "$PROJ" 2>"$WORK/err"; rc=$?
    assert_rc "refresh rc 0" "$rc" "0"
    assert_contains "the pin now names the refreshed jupyterlab" "$(cat "$JD/labsh-server.pin")" "jupyterlab==4.1.0"
    assert_contains "the previous pin is kept for rollback" "$(cat "$JD/labsh-server.pin.prev")" "jupyterlab==4.0.0"
    assert_not_contains "the candidate was built UNCONSTRAINED (never through the shim's pin)" "$(cat "$ARGV_LOG")" "--constraints"
    assert_contains "…from the RECORDED spec" "$(cat "$ARGV_LOG")" "--python 3.12 --from jupyterlab --with jupyterlmod python -c"
    assert_contains "meta says it came from a refresh" "$(cat "$JD/labsh-server.pin.meta")" "source=refresh"
    assert_contains "…and records the attempt's RESULT (swapped)" "$(cat "$JD/labsh-server.pin.meta")" "refresh_result=swapped"

    echo "## refresh: nothing new upstream ⇒ 'already current', pin untouched"
    cp "$JD/labsh-server.pin" "$WORK/pin.before"
    PATH="$SHIMPATH" FAKE_LAB_VERSION=4.1.0 "$PIN_TOOL" refresh "$PROJ" 2>"$WORK/err"; rc=$?
    assert_rc "refresh rc 0" "$rc" "0"
    assert_contains "it says already current" "$(cat "$WORK/err")" "already current"
    cmp -s "$WORK/pin.before" "$JD/labsh-server.pin"; assert_rc "pin byte-identical" "$?" "0"

    echo "## refresh NEGATIVE: a candidate that does not SERVE is never swapped in"
    PATH="$SHIMPATH" FAKE_LAB_VERSION=4.2.0 FAKE_LAB_BROKEN=1 LABSH_PIN_SMOKE_TIMEOUT=10 \
        "$PIN_TOOL" refresh "$PROJ" 2>"$WORK/err"; rc=$?
    assert_rc "a failed smoke test ⇒ REFUSED rc 3" "$rc" "3"
    assert_contains "the pin still names the last GOOD env" "$(cat "$JD/labsh-server.pin")" "jupyterlab==4.1.0"
    assert_contains "…and it says the pin was NOT swapped" "$(cat "$WORK/err")" "pin NOT swapped"
    assert_contains "…and records the failed RESULT for the operator (smoke-failed)" "$(cat "$JD/labsh-server.pin.meta")" "refresh_result=smoke-failed"

    echo "## refresh: no recorded spec ⇒ REFUSED, nothing changed"
    mv "$JD/labsh-server.spec" "$WORK/spec.aside"
    PATH="$SHIMPATH" "$PIN_TOOL" refresh "$PROJ" >/dev/null 2>&1; rc=$?
    assert_rc "no spec ⇒ rc 3" "$rc" "3"
    mv "$WORK/spec.aside" "$JD/labsh-server.spec"
fi

echo "## demote: a pin that RESOLVED but whose server failed health rolls back to .prev, else quarantines"
PINNED_LOG='labsh-uvx-shim: resolving against the server-env pin x (95 packages)'
printf 'jupyterlab==4.2.0\n' > "$JD/labsh-server.pin"; printf 'jupyterlab==4.1.0\n' > "$JD/labsh-server.pin.prev"
rm -f "$JD/labsh-server.pin.bad"; printf '%s\n' "$PINNED_LOG" > "$JD/labsh.bg.log"
PATH="$BASEPATH" "$PIN_TOOL" demote "$PROJ" >/dev/null 2>&1
assert_contains "with a different .prev: the PREVIOUS pin is restored" "$(cat "$JD/labsh-server.pin")" "jupyterlab==4.1.0"
assert_contains "…and the failing pin is kept at .bad" "$(cat "$JD/labsh-server.pin.bad")" "jupyterlab==4.2.0"
rm -f "$JD/labsh-server.pin.bad" "$JD/labsh-server.pin.prev"
PATH="$BASEPATH" "$PIN_TOOL" demote "$PROJ" >/dev/null 2>&1
assert_no_file "with no .prev: the pin is QUARANTINED (the next start runs unpinned)" "$JD/labsh-server.pin"
assert_contains "…to .bad" "$(cat "$JD/labsh-server.pin.bad")" "jupyterlab==4.1.0"
printf 'jupyterlab==4.1.0\n' > "$JD/labsh-server.pin"
printf 'labsh-uvx-shim: no server-env pin yet — starting UNPINNED\n' > "$JD/labsh.bg.log"
PATH="$BASEPATH" "$PIN_TOOL" demote "$PROJ" >/dev/null 2>&1
assert_file_exists "the last start was NOT pinned ⇒ demote touches nothing" "$JD/labsh-server.pin"

echo "## supervisor: a FAILING refresh is retried after the backoff, never every round (skeptic labshcoldsk)"
# The skeptic's harness: the supervisor's refresh helpers lifted verbatim, the
# pin tool stubbed to FAIL, refreshed_at 8 days back; five rounds must launch
# ONE refresh. RED on 2bcf6b6c (it launched on every round).
SUPD="$WORK/sup"; mkdir -p "$SUPD/.jupyter"
STUB_PIN="$WORK/pin-stub.sh"; STUB_CALLS="$WORK/pin-stub.calls"; : > "$STUB_CALLS"
printf '#!/usr/bin/env bash\necho "$1" >> "%s"\n[[ "$1" == refresh ]] && exit 1\nexit 0\n' "$STUB_CALLS" > "$STUB_PIN"; chmod +x "$STUB_PIN"
SUPLOG="$WORK/sup.log"; : > "$SUPLOG"
# NO TERMINATOR inside these subshells (test-subshell-exit-guards.sh, #1339):
# a broken fixture prints FIXTURE-BROKEN and skips the body, so the marker
# lines the assertions below look for are absent and they go RED themselves.
(
    log() { printf '%s\n' "$*" >> "$SUPLOG"; }
    PIN_TOOL="$STUB_PIN"; PROJECT_DIR="$SUPD"
    if cd "$SUPD" \
       && eval "$(sed -n '/^REPIN_DAYS=/,/^# After a start that did not become healthy/p' "$SUPERVISOR")" \
       && declare -F _maybe_refresh_pin >/dev/null; then
    printf 'jupyterlab==4.1.0\n' > .jupyter/labsh-server.pin
    printf 'refreshed_at=%s\n' "$(( $(date +%s) - 8 * 86400 ))" > .jupyter/labsh-server.pin.meta
    for _r in 1 2 3 4 5; do _maybe_refresh_pin; [[ -n "$REFRESH_PID" ]] && wait "$REFRESH_PID" 2>/dev/null; done
    echo "launches_5_rounds=$(grep -c '^refresh$' "$STUB_CALLS")"
    printf '%s\n' "$(( $(date +%s) - 25 * 3600 ))" > .jupyter/labsh-pin.refresh-attempt
    _maybe_refresh_pin; [[ -n "$REFRESH_PID" ]] && wait "$REFRESH_PID" 2>/dev/null
    echo "launches_after_backoff=$(grep -c '^refresh$' "$STUB_CALLS")"
    else
        echo "FIXTURE-BROKEN: could not enter $SUPD or lift _maybe_refresh_pin from $SUPERVISOR"
    fi
) > "$WORK/sup.out" 2>&1
assert_contains "five rounds against a FAILING refresh launch it ONCE" "$(cat "$WORK/sup.out")" "launches_5_rounds=1"
assert_contains "the failure's rc is reaped and LOGGED with the backoff" "$(cat "$SUPLOG")" "finished rc=1 (NOT swapped); next attempt no sooner than 24h"
assert_contains "…and once the retry window has passed it IS retried (not disabled)" "$(cat "$WORK/sup.out")" "launches_after_backoff=2"

echo "## supervisor: two consecutive PINNED starts that fail health demote the pin; unpinned starts never do"
: > "$STUB_CALLS"
(
    log() { printf '%s\n' "$*" >> "$SUPLOG"; }
    PIN_TOOL="$STUB_PIN"; PROJECT_DIR="$SUPD"
    if cd "$SUPD" \
       && eval "$(sed -n '/^PINNED_FAIL_LIMIT=/,/^}/p' "$SUPERVISOR")" \
       && declare -F _after_failed_start >/dev/null; then
    printf 'jupyterlab==4.1.0\n' > .jupyter/labsh-server.pin
    printf '%s\n' "$PINNED_LOG" > .jupyter/labsh.bg.log
    _after_failed_start; echo "demotes_after_1=$(grep -c '^demote$' "$STUB_CALLS")"
    _after_failed_start; echo "demotes_after_2=$(grep -c '^demote$' "$STUB_CALLS")"
    printf 'labsh-uvx-shim: no server-env pin yet — starting UNPINNED\n' > .jupyter/labsh.bg.log
    _after_failed_start; _after_failed_start; _after_failed_start
    echo "demotes_after_unpinned=$(grep -c '^demote$' "$STUB_CALLS")"
    else
        echo "FIXTURE-BROKEN: could not enter $SUPD or lift _after_failed_start from $SUPERVISOR"
    fi
) > "$WORK/sup2.out" 2>&1
assert_contains "ONE failed pinned start does not demote (a transient cause is not the pin's)" "$(cat "$WORK/sup2.out")" "demotes_after_1=0"
assert_contains "the SECOND consecutive one does" "$(cat "$WORK/sup2.out")" "demotes_after_2=1"
assert_contains "failed UNPINNED starts never demote a pin" "$(cat "$WORK/sup2.out")" "demotes_after_unpinned=1"

echo "## seed (#1692): with NO shim-recorded spec, capture derives it from the RUNNING build's own argv"
# A server started by pre-#1677 code was never launched through the shim, so
# the first restart after the pin lands had no spec and ran UNPINNED — measured
# cold on that very deploy. The spec is read from the live build's argv, behind
# the shared identity gates. A FAKE build: a copy of bash named `uv`, cwd = the
# workdir, labsh's argv shape, recorded in bg.pid (the gates read /proc).
SEEDWD="$WORK/seedwd"; mkdir -p "$SEEDWD/.jupyter"
cp "$(command -v bash)" "$WORK/uv"
printf 'PORT=9911\n' > "$SEEDWD/.jupyter/labsh-service.env"
( cd "$SEEDWD" && exec "$WORK/uv" -c 'sleep 60; :' tool uvx --python 3.12 --from jupyterlab \
    --with jupyterlmod jupyter-lab --port 9911 --no-browser ) >/dev/null 2>&1 &
SEEDPID=$!; echo "$SEEDPID" > "$SEEDWD/.jupyter/labsh.bg.pid"
( cd "$WORK" && exec "$WORK/uv" -c 'sleep 60; :' tool uvx --python 3.12 --from jupyterlab \
    --with EVIL jupyter-lab --port 9911 ) >/dev/null 2>&1 &
IMPPID=$!
for _ in $(seq 1 60); do [[ -r "/proc/$IMPPID/cmdline" && -r "/proc/$SEEDPID/cmdline" ]] && break; sleep 0.05; done
sleep 0.3
_lift_argv=$(sed -n '/^spec_from_running_argv() {/,/^}/p' "$PIN_TOOL")
SEEDOUT=$( PROJECT_DIR="$SEEDWD" JDIR="$SEEDWD/.jupyter"; . "$_mon/_labsh_build_evidence.sh"; eval "$_lift_argv"; spec_from_running_argv | tr '\n' ' '; echo "rc=${PIPESTATUS[0]}" )
assert_eq "the spec is exactly the args labsh passed before jupyter-lab" "$SEEDOUT" "--python 3.12 --from jupyterlab --with jupyterlmod rc=0"
echo "$IMPPID" > "$SEEDWD/.jupyter/labsh.bg.pid"
SEEDOUT=$( PROJECT_DIR="$SEEDWD" JDIR="$SEEDWD/.jupyter"; . "$_mon/_labsh_build_evidence.sh"; eval "$_lift_argv"; spec_from_running_argv >/dev/null; echo "rc=$?" )
assert_eq "an IMPOSTOR with the same argv shape from another cwd yields NO spec (identity, not resemblance)" "$SEEDOUT" "rc=1"
kill "$SEEDPID" "$IMPPID" 2>/dev/null; wait "$SEEDPID" "$IMPPID" 2>/dev/null

echo "## seed (#1692): svc.sh captures from a HEALTHY labsh server with no pin, just before it stops it"
SSTUB_DIR="$WORK/svcstub"; mkdir -p "$SSTUB_DIR"; SEEDCALLS="$WORK/seed.calls"; : > "$SEEDCALLS"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 0\n' "$SEEDCALLS" > "$SSTUB_DIR/labsh-pin.sh"; chmod +x "$SSTUB_DIR/labsh-pin.sh"
rm -f "$SEEDWD/.jupyter/labsh-server.pin"
SEEDRES=$(
    _script_dir="$SSTUB_DIR"; HEALTHY=1
    _recover_service_healthy() { (( HEALTHY )); }
    eval "$(sed -n '/^_seed_labsh_pin() {/,/^}/p' "$SVC")"
    if ! declare -F _seed_labsh_pin >/dev/null; then echo "FIXTURE-BROKEN: _seed_labsh_pin not lifted"; else
        _seed_labsh_pin jupyterlab "$SEEDWD" /x/labsh-supervised.sh h 2>/dev/null; echo "healthy_nopin=$(grep -c "^capture $SEEDWD$" "$SEEDCALLS")"
        printf 'jupyterlab==4.1.0\n' > "$SEEDWD/.jupyter/labsh-server.pin"
        _seed_labsh_pin jupyterlab "$SEEDWD" /x/labsh-supervised.sh h 2>/dev/null; echo "with_pin=$(grep -c . "$SEEDCALLS")"
        rm -f "$SEEDWD/.jupyter/labsh-server.pin"; HEALTHY=0
        _seed_labsh_pin jupyterlab "$SEEDWD" /x/labsh-supervised.sh h 2>/dev/null; echo "unhealthy=$(grep -c . "$SEEDCALLS")"
        HEALTHY=1
        _seed_labsh_pin other "$SEEDWD" ./serve-supervised.sh h 2>/dev/null; echo "non_labsh=$(grep -c . "$SEEDCALLS")"
    fi
)
assert_contains "labsh + healthy + no pin ⇒ capture is called before the stop" "$SEEDRES" "healthy_nopin=1"
assert_contains "a pin already exists ⇒ nothing (the relaunch is already pinned)" "$SEEDRES" "with_pin=1"
assert_contains "an UNHEALTHY server is never pinned" "$SEEDRES" "unhealthy=1"
assert_contains "a non-labsh service is never touched" "$SEEDRES" "non_labsh=1"

echo "## seed (#1692) WIRING: the REAL \`svc.sh stop\` seeds the pin before it stops a healthy pre-shim server"
# The cases above lift `_seed_labsh_pin` and call it directly, so they cannot
# see whether `_stop_service` CALLS it — skeptic labshseedsk measured that
# commenting out the call site SURVIVED 57/57. This case runs the real svc.sh
# `stop` against a fixture (adapted from its harness, reports/labshseedsk-harness/
# pair.sh): a healthy server with NO pin and NO shim spec (the pre-#1677
# state), and asserts a pin exists afterwards. Safety: the service is named
# `labshpintest` (never `jupyterlab`), state and registry live under $WORK, the
# fake supervisor is a scratch file, and every process is stopped by the pid
# this suite started.
WIRED=0
if [[ -n "$UV_BIN" && -n "$FAKE_PY" ]]; then
    WIRED=1
    WW="$WORK/wire"; WJ="$WW/wd/.jupyter"; mkdir -p "$WJ" "$WW/state/services" "$WW/sup"
    WPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
    # The fake supervisor RUNS the fake server, so the server is in the
    # supervisor's process group and svc.sh's group TERM stops it — as the real
    # supervisor's on_term stops the real one (`labsh stop`). Outside the group,
    # svc.sh correctly reports "healthcheck still passes after stop" and exits 1.
    cat > "$WW/srv.py" <<'PYEOF'
import http.server as h, sys
class H(h.BaseHTTPRequestHandler):
    def do_GET(s): s.send_response(200); s.end_headers(); s.wfile.write(b"{}")
    def log_message(s, *a): pass
h.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
    printf '#!/usr/bin/env bash\npython3 %q %q &\nwait\n' "$WW/srv.py" "$WPORT" > "$WW/sup/labsh-supervised.sh"; chmod +x "$WW/sup/labsh-supervised.sh"
    printf 'labshpintest\t%s\t%s\t%s\t%s\n' "$WW/wd" "$WW/sup/labsh-supervised.sh" "$_mon/jupyter-health.sh" "$WW/svc.log" > "$WW/registry"
    setsid bash -c "echo \$\$ > '$WW/state/services/labshpintest.pid'; exec '$WW/sup/labsh-supervised.sh'" </dev/null >/dev/null 2>&1 &
    "$WORK/mkenv.sh" "$WW/env" 4.6.4 0 >/dev/null 2>&1
    printf 'PORT=%s\nSCHEME=http\n' "$WPORT" > "$WJ/labsh-service.env"; echo tok > "$WJ/token"
    echo "Jupyter Server is running at http://127.0.0.1:$WPORT/lab" > "$WJ/labsh.bg.log"
    ( cd "$WW/wd" && exec "$WORK/uv" -c "PATH='$WW/env/bin':/usr/bin:/bin sleep 120 & wait" \
        tool uvx --python 3.12 --from jupyterlab --with jupyterlmod jupyter-lab --port "$WPORT" --no-browser ) </dev/null >/dev/null 2>&1 &
    WBUILD=$!; echo "$WBUILD" > "$WJ/labsh.bg.pid"
    for _ in $(seq 1 60); do [[ -s "$WW/state/services/labshpintest.pid" ]] && "$_mon/jupyter-health.sh" "$WW/wd" >/dev/null 2>&1 && break; sleep 0.1; done
    sleep 0.5
    WSUP=$(cat "$WW/state/services/labshpintest.pid" 2>/dev/null)
    assert_no_file "PRE: no pin before the stop (the pre-#1677 state)" "$WJ/labsh-server.pin"
    NEXUS_ROOT="$(cd "$_mon/.." && pwd)" NEXUS_STATE_DIR="$WW/state" NEXUS_SERVICES_REGISTRY="$WW/registry" \
        timeout 120 "$SVC" stop labshpintest > "$WW/stop.out" 2>&1 </dev/null
    WRC=$?
    assert_rc "the real svc.sh stop exits 0" "$WRC" "0"
    assert_contains "…and says it SEEDED the pin before stopping" "$(cat "$WW/stop.out")" "seeded the server-env pin from the running healthy server"
    assert_file_exists "a pin EXISTS after the real stop — the relaunch will resolve pinned" "$WJ/labsh-server.pin"
    assert_contains "…frozen from the env that was SERVING" "$(cat "$WJ/labsh-server.pin" 2>/dev/null)" "jupyterlab==4.6.4"
    assert_eq "…and the argv-derived spec is PUBLISHED beside it, identical to what the pin was captured under" \
        "$(cmp -s "$WJ/labsh-server.spec" "$WJ/labsh-server.pin.spec" && tr '\n' ' ' < "$WJ/labsh-server.spec")" \
        "--python 3.12 --from jupyterlab --with jupyterlmod "
    assert_eq "…and the stop took the server DOWN (healthcheck now fails)" \
        "$("$_mon/jupyter-health.sh" "$WW/wd" >/dev/null 2>&1 && echo UP || echo DOWN)" "DOWN"
    kill "$WBUILD" 2>/dev/null; [[ "$WSUP" =~ ^[0-9]+$ ]] && kill -- "-$WSUP" 2>/dev/null
    wait "$WBUILD" 2>/dev/null
else
    th_skip "wiring case: no \`uv\` on PATH, or no uv-managed Python >= 3.8 for the fake server env"
fi

echo "## quarantine: only on positive evidence of a RESOLUTION failure against the pin"
printf 'jupyterlab==4.1.0\n' > "$JD/labsh-server.pin"; rm -f "$JD/labsh-server.pin.bad"
printf 'labsh-uvx-shim: resolving against the server-env pin x\nerror: something else broke\n' > "$JD/labsh.bg.log"
PATH="$BASEPATH" "$PIN_TOOL" quarantine "$PROJ" >/dev/null 2>&1
assert_file_exists "an unrelated failure does NOT quarantine the pin" "$JD/labsh-server.pin"
printf 'labsh-uvx-shim: resolving against the server-env pin x\n  × No solution found when resolving tool dependencies:\n' > "$JD/labsh.bg.log"
PATH="$BASEPATH" "$PIN_TOOL" quarantine "$PROJ" >/dev/null 2>&1
assert_no_file "a pin uv could not RESOLVE is moved aside" "$JD/labsh-server.pin"
assert_file_exists "…to .bad, for the operator to inspect" "$JD/labsh-server.pin.bad"
printf 'labsh-uvx-shim: no server-env pin yet — starting UNPINNED\n  × No solution found\n' > "$JD/labsh.bg.log"
printf 'jupyterlab==4.1.0\n' > "$JD/labsh-server.pin"
PATH="$BASEPATH" "$PIN_TOOL" quarantine "$PROJ" >/dev/null 2>&1
assert_file_exists "an UNPINNED start's resolution failure never touches a pin" "$JD/labsh-server.pin"

# EXACT assertion total, so an assertion lost to a subshell or an early exit is
# RED rather than a quieter green: 41 always, +15 when the refresh block runs,
# +7 when the real-svc.sh wiring case runs (both need a uv-managed Python).
_EXPECTED_ASSERTIONS=$(( 41 + 15 * REFRESH_RAN + 7 * WIRED ))
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
