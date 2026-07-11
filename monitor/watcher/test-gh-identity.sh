#!/usr/bin/env bash
# test-gh-identity.sh — hermetic, offline tests for the fail-CLOSED bot identity.
#
# Context. The nexus promises "a bare `gh <write>` posts as the bot". That was
# enforced only by PATH order: monitor/ghwrap shadows the real gh. PATH order is
# not a boundary — any shell rc that re-prepends its own bin dir wins the race,
# `gh` resolves to a real gh, and that gh authenticates as the OPERATOR from the
# ambient credential store. Observed live on 2026-07-09 on a healthy filesystem:
# `command -v gh` → ~/.linuxbrew/bin/gh, and `gh api user --jq .login` → the
# operator. Issue your-org/your-nexus#269 was authored that way.
#
# The fix removes the CREDENTIAL from the ambient environment instead of
# shadowing the BINARY: locals-env.sh scopes GH_CONFIG_DIR to a credential-free
# dir, and gh-shim.sh opts back in explicitly on the paths that legitimately
# need the operator identity (reads, `gh auth …`, audited GH_IMPERSONATE).
#
# BOTH DIRECTIONS. T1, T1b, T2, T4, T5, T6b and T8 FAIL against pre-fix code and
# PASS against post-fix code. Prove that by running against the pre-fix tree:
#
#     pre=$(mktemp -d); mkdir -p "$pre/monitor"
#     for f in locals-env.sh gh-shim.sh link-nexus-tools.sh; do
#         git show origin/dev:monitor/$f > "$pre/monitor/$f"
#     done
#     chmod +x "$pre/monitor/link-nexus-tools.sh"
#     MONITOR_DIR="$pre/monitor" ./monitor/watcher/test-gh-identity.sh   # expect failures
#     ./monitor/watcher/test-gh-identity.sh                              # expect all pass
#
# Fully offline: no network, no real `gh`, no real token. The stub `gh` models
# gh's credential resolution (GH_TOKEN wins; else hosts.yml under GH_CONFIG_DIR;
# else under XDG_CONFIG_HOME/gh).

set -uo pipefail

PASS=0; FAIL=0
ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="${MONITOR_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LOCALS_ENV="$MONITOR_DIR/locals-env.sh"
GH_SHIM="$MONITOR_DIR/gh-shim.sh"
LINK_TOOLS="$MONITOR_DIR/link-nexus-tools.sh"

for f in "$LOCALS_ENV" "$GH_SHIM" "$LINK_TOOLS"; do
    [ -r "$f" ] || { printf 'FATAL: missing %s\n' "$f" >&2; exit 2; }
done

TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# Never inherit these from the caller's shell. NEXUS_LOCALS matters most:
# link-nexus-tools.sh honours it over $NEXUS_ROOT/locals, so an agent shell that
# exports it (locals-env.sh does) makes T8 silently provision the REAL tree
# instead of the fixture — the test then passes for the wrong reason. Same class
# as your-org/nexus-code#256 (a sandbox-exported var masking a clean-CI failure).
unset GH_TOKEN GH_CONFIG_DIR GH_IMPERSONATE GH_IMPERSONATE_REASON \
      WATCHER_WINDOW NEXUS_GH_CONFIG_SCOPED NEXUS_OPERATOR_GH_CONFIG_DIR \
      NEXUS_LOCALS_PATH_ONLY NEXUS_LOCALS 2>/dev/null || true

# ── fixture: an "operator" gh credential store ────────────────────────────────
OPCFG_HOME="$TMP/opcfg"; OPCFG_DIR="$OPCFG_HOME/gh"
mkdir -p "$OPCFG_DIR" "$TMP/home" "$TMP/scoped"
printf 'github.com:\n    oauth_token: OPERATOR_PAT_SENTINEL\n    user: operator\n' \
    > "$OPCFG_DIR/hosts.yml"

# ── fixture: a stub `gh` modelling real gh's credential resolution ───────────
STUB_BIN="$TMP/stubbin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ -n "${GH_TOKEN:-}" ]; then echo "token=$GH_TOKEN"; exit 0; fi
cfg="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
if [ -f "$cfg/hosts.yml" ]; then
    echo "token=$(awk -F': ' '/oauth_token/{print $2}' "$cfg/hosts.yml")"; exit 0
fi
echo "gh: To get started with GitHub CLI, please run: gh auth login" >&2
exit 4
STUB
chmod +x "$STUB_BIN/gh"

# ═══ T1 / T1b — locals-env.sh scopes GH_CONFIG_DIR, records the operator's ═══
# `env -u NEXUS_ROOT` also guards the your-org/nexus-code#256 class: a bare
# $NEXUS_ROOT under `set -u` passes in-sandbox (exported) and dies on clean CI.
t1_out=$(env -u NEXUS_ROOT XDG_CONFIG_HOME="$OPCFG_HOME" HOME="$TMP/home" \
    bash -c '. "$1" >/dev/null 2>&1
             printf "%s\n%s\n" "${GH_CONFIG_DIR:-<unset>}" "${NEXUS_OPERATOR_GH_CONFIG_DIR:-<unset>}"' \
    _ "$LOCALS_ENV" 2>/dev/null)
t1_cfg=$(printf '%s\n' "$t1_out" | sed -n 1p)
t1_op=$(printf '%s\n' "$t1_out" | sed -n 2p)

if [ "$t1_cfg" != "<unset>" ] && [ "$t1_cfg" != "$OPCFG_DIR" ]; then
    ok "T1 locals-env.sh scopes GH_CONFIG_DIR away from the operator store"
else
    fail "T1 GH_CONFIG_DIR not scoped (got '$t1_cfg'; operator store '$OPCFG_DIR')"
fi
if [ "$t1_op" = "$OPCFG_DIR" ]; then
    ok "T1b NEXUS_OPERATOR_GH_CONFIG_DIR points at the operator store"
else
    fail "T1b NEXUS_OPERATOR_GH_CONFIG_DIR='$t1_op', expected '$OPCFG_DIR'"
fi

# ═══ T1c — locals-env.sh names NO home path in executable code ══════════════
# The nexus toolchain is home-independent by contract; monitor/watcher/test-
# bootstrap-venv.sh check 12 enforces it and caught the first draft of this
# change. Pinned here too, next to the code that tempted the violation.
if grep -vE '^[[:space:]]*#' "$LOCALS_ENV" | grep -qE '(\$HOME|/\.local/|/\.cache/uv|~/)'; then
    fail "T1c locals-env.sh references a home path in executable code"
else
    ok "T1c locals-env.sh names no home path in executable code"
fi

# ═══ T1d — with NEITHER GH_CONFIG_DIR NOR XDG_CONFIG_HOME set, the scoping ══
#      still happens and the operator dir is left for gh-shim to resolve.
t1d=$(env -u NEXUS_ROOT -u XDG_CONFIG_HOME HOME="$TMP/home" \
    bash -c '. "$1" >/dev/null 2>&1
             printf "%s|%s|%s\n" "${GH_CONFIG_DIR:-<unset>}" \
                 "${NEXUS_OPERATOR_GH_CONFIG_DIR:-<unset>}" "${NEXUS_GH_CONFIG_SCOPED:-<unset>}"' \
    _ "$LOCALS_ENV" 2>/dev/null)
case "$t1d" in
    *"|<unset>|1")
        case "$t1d" in
            "<unset>|"*) fail "T1d GH_CONFIG_DIR not scoped without XDG_CONFIG_HOME" ;;
            *) ok "T1d scoping happens with no XDG_CONFIG_HOME; operator dir left to the shim" ;;
        esac ;;
    *) fail "T1d unexpected ($t1d)" ;;
esac

# ═══ T2 — THE REGRESSION: a gh reached WITHOUT the shim cannot authenticate ══
# Models the real bypass: source locals-env.sh, then strip monitor/ghwrap from
# PATH (as a shell rc re-prepend effectively does) and call a bare `gh`.
t2_out=$(env -u NEXUS_ROOT XDG_CONFIG_HOME="$OPCFG_HOME" HOME="$TMP/home" \
    STUB_BIN="$STUB_BIN" bash -c '
        . "$1" >/dev/null 2>&1
        PATH=$(printf %s "$PATH" | tr ":" "\n" | grep -v "/monitor/ghwrap$" | paste -sd:)
        PATH="$STUB_BIN:$PATH"; export PATH
        command gh auth token 2>&1' _ "$LOCALS_ENV")
if printf '%s' "$t2_out" | grep -q 'OPERATOR_PAT_SENTINEL'; then
    fail "T2 a bypassing bare gh STILL reaches the operator PAT (fail-OPEN)"
else
    ok "T2 a bypassing bare gh cannot authenticate (fail-closed)"
fi

# ── shim harness. _ghs_realgh is pre-defined, so gh-shim.sh's guard keeps it. ─
shim_call() {
    bash -c '
        _ghs_realgh() { printf "TOKEN=%s CFG=%s\n" "${GH_TOKEN:-}" "${GH_CONFIG_DIR:-}"; }
        . "$1" >/dev/null 2>&1
        shift
        gh "$@"' _ "$GH_SHIM" "$@" 2>&1
}
MINT="$TMP/mint.sh"; printf '#!/usr/bin/env bash\necho bot-tok\n' > "$MINT"; chmod +x "$MINT"

export NEXUS_ROOT="$TMP/nexus" MINT_TOKEN_BIN="$MINT"

# ═══ T3 — regression guard: WRITE verbs still inject the bot token ═══════════
t3=$(NEXUS_OPERATOR_GH_CONFIG_DIR="$OPCFG_DIR" GH_CONFIG_DIR="$TMP/scoped" \
     shim_call issue comment 1 -b hi)
case "$t3" in
    *"TOKEN=bot-tok"*) ok "T3 WRITE verb still injects the bot token" ;;
    *) fail "T3 WRITE verb did not inject the bot token (got: $t3)" ;;
esac

# ═══ T4 — READS run with the operator's config dir restored ═════════════════
t4=$(NEXUS_OPERATOR_GH_CONFIG_DIR="$OPCFG_DIR" GH_CONFIG_DIR="$TMP/scoped" \
     shim_call pr view 1)
case "$t4" in
    *"CFG=$OPCFG_DIR"*) ok "T4 READ restores the operator config dir" ;;
    *) fail "T4 READ did not restore the operator config dir (got: $t4)" ;;
esac

# ═══ T4b — shim resolves gh's OWN default when locals-env recorded no dir ══
#      (scoped, but neither GH_CONFIG_DIR nor XDG_CONFIG_HOME was set upstream)
t4b=$(NEXUS_GH_CONFIG_SCOPED=1 GH_CONFIG_DIR="$TMP/scoped" HOME="$TMP/home" \
      env -u NEXUS_OPERATOR_GH_CONFIG_DIR -u XDG_CONFIG_HOME \
      bash -c '
        _ghs_realgh() { printf "CFG=%s\n" "${GH_CONFIG_DIR:-}"; }
        . "$1" >/dev/null 2>&1; shift; gh "$@"' _ "$GH_SHIM" pr view 1 2>&1)
case "$t4b" in
    *"CFG=$TMP/home/.config/gh"*) ok "T4b shim falls back to gh's own default config dir" ;;
    *) fail "T4b shim fallback wrong (got: $t4b)" ;;
esac

# ═══ T4c — shim does NOT touch GH_CONFIG_DIR when locals-env never ran ═════
t4c=$(env -u NEXUS_OPERATOR_GH_CONFIG_DIR -u NEXUS_GH_CONFIG_SCOPED \
      GH_CONFIG_DIR="$TMP/scoped" bash -c '
        _ghs_realgh() { printf "CFG=%s\n" "${GH_CONFIG_DIR:-}"; }
        . "$1" >/dev/null 2>&1; shift; gh "$@"' _ "$GH_SHIM" pr view 1 2>&1)
case "$t4c" in
    *"CFG=$TMP/scoped"*) ok "T4c shim is a no-op when locals-env.sh never ran" ;;
    *) fail "T4c shim altered GH_CONFIG_DIR without scoping (got: $t4c)" ;;
esac

# ═══ T5 — `gh auth token` restores operator config (ng fetch-asset needs it) ═
t5=$(NEXUS_OPERATOR_GH_CONFIG_DIR="$OPCFG_DIR" GH_CONFIG_DIR="$TMP/scoped" \
     shim_call auth token)
case "$t5" in
    *"CFG=$OPCFG_DIR"*) ok "T5 'gh auth token' restores the operator config dir" ;;
    *) fail "T5 'gh auth token' did not restore the operator config dir (got: $t5)" ;;
esac

# ═══ T6a — impersonation without a stated reason is still refused ═══════════
t6a=$(GH_IMPERSONATE=1 shim_call issue create; printf 'rc=%s' "$?")
case "$t6a" in
    *"without a stated reason"*) ok "T6a impersonation without a reason is refused" ;;
    *) fail "T6a impersonation without a reason was NOT refused (got: $t6a)" ;;
esac

# ═══ T6b — audited impersonation restores the operator config dir ══════════
t6b=$(GH_IMPERSONATE=1 GH_IMPERSONATE_REASON=test \
      NEXUS_OPERATOR_GH_CONFIG_DIR="$OPCFG_DIR" GH_CONFIG_DIR="$TMP/scoped" \
      shim_call issue create)
case "$t6b" in
    *"CFG=$OPCFG_DIR"*) ok "T6b audited impersonation restores the operator config dir" ;;
    *) fail "T6b impersonation did not restore the operator config dir (got: $t6b)" ;;
esac

# ═══ T7 — a preset GH_TOKEN is never overridden ════════════════════════════
t7=$(GH_TOKEN=preset shim_call issue comment 1 -b x)
case "$t7" in
    *"TOKEN=preset"*) ok "T7 a preset GH_TOKEN is never overridden" ;;
    *) fail "T7 a preset GH_TOKEN was overridden (got: $t7)" ;;
esac

# ═══ T8 — link-nexus-tools.sh fails LOUD when a link cannot be created ══════
LNT_ROOT="$TMP/lnt"
mkdir -p "$LNT_ROOT/monitor/watcher" "$LNT_ROOT/locals/bin" "$LNT_ROOT/node_modules/.bin"
: > "$LNT_ROOT/monitor/ng";               chmod +x "$LNT_ROOT/monitor/ng"
: > "$LNT_ROOT/monitor/watcher/entry.sh"; chmod +x "$LNT_ROOT/monitor/watcher/entry.sh"
: > "$LNT_ROOT/node_modules/.bin/claude"; chmod +x "$LNT_ROOT/node_modules/.bin/claude"
chmod 555 "$LNT_ROOT/locals/bin"          # mkdir -p succeeds; every `ln` fails
lnt_out=$(env -u NEXUS_LOCALS NEXUS_ROOT="$LNT_ROOT" bash "$LINK_TOOLS" --quiet 2>&1); lnt_rc=$?
chmod 755 "$LNT_ROOT/locals/bin"
if [ "$lnt_rc" -ne 0 ]; then
    ok "T8 link-nexus-tools.sh exits non-zero when links cannot be created (rc=$lnt_rc)"
else
    fail "T8 link-nexus-tools.sh exited 0 despite failing to link (fail-OPEN)"
fi
case "$lnt_out" in
    *"failed to link"*) ok "T8b the failure is reported on stderr, even with --quiet" ;;
    *) fail "T8b expected a 'failed to link' warning (got: $lnt_out)" ;;
esac

printf '\n%d passed, %d failed  (MONITOR_DIR=%s)\n' "$PASS" "$FAIL" "$MONITOR_DIR"
[ "$FAIL" -eq 0 ]
