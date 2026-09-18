#!/usr/bin/env bash
# monitor/cc-harness/_lib.sh — shared library for the real-binary CC
# test harness. Boots the *real* `claude` against the auth-free mock
# backend (mock-backend.py) in a dedicated, isolated tmux socket, then
# drives it and classifies its panes with the production
# monitor/pane-state.sh.
#
# This is the complement to monitor/watcher/test-integration/_harness.sh:
# that harness drives a fully *fake* `claude` shim (stub-claude.sh); this
# one drives the *real* binary so the actual boot / hook / tool-loop /
# pane-rendering surface is exercised. The mock supplies the "model"
# (canned or control-file-injected responses) with NO Anthropic auth and
# NO network egress.
#
# Globals set by cch_setup (exported for child processes):
#   CCH_DIR        tmpdir root for this run
#   CCH_CFG        isolated CLAUDE_CONFIG_DIR (no real creds ever live here)
#   CCH_WORKDIR    pinned project cwd for the booted claude (pre-trusted)
#   CCH_STATE_DIR  $CCH_DIR/state (NEXUS_STATE_DIR for pane-state)
#   CCH_SOCKET     tmux -L socket name (unique per run). `default` is
#                  SYMLINKED to it inside CCH_TMUX_TMPDIR so pane-state.sh's
#                  bare `tmux` calls land here too (your-org/nexus-code#1042 A)
#   CCH_TMUX_TMPDIR  private TMUX_TMPDIR — THE isolation boundary. A PATH-front
#                  shim can be force-fronted over our shadow; it cannot change
#                  where tmux computes its socket path from.
#   CCH_SESSION    tmux session name
#   CCH_MOCK_PORT  port the mock bound (discovered when launched with :0)
#   CCH_MOCK_PID   pid of the mock backend
#   CCH_CONTROL    path to the injectable control.json
#   CCH_TMUXWRAP   PATH-shadow tmux wrapper that injects -L $CCH_SOCKET
#                  (defence in depth only — NOT the isolation mechanism)
#   CLAUDE_BIN     resolved real claude binary (override to gate a candidate)
#
# Conventions mirror _harness.sh: cch_tmux for socket-scoped tmux,
# wait_for/hold_false for polling predicates, assert_* from
# _test_helpers.sh.

set -uo pipefail

_cch_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CCH_REPO_ROOT=$(cd "$_cch_self_dir/../.." && pwd)

# trash_path: rename-aside instead of unlink for teardown, so a still-
# releasing claude config dir over NFS can't make `rm` fail with
# `.nfs`/"Directory not empty".
# shellcheck source=../_trash.sh
. "$CCH_REPO_ROOT/monitor/_trash.sh"
CCH_MOCK_PY="$_cch_self_dir/mock-backend.py"
CCH_PANE_STATE="$CCH_REPO_ROOT/monitor/pane-state.sh"

# Is $1 a SCRIPT (has a `#!` magic) rather than a real executable?
#
# THIS IS THE SELECTION PREDICATE, and it is deliberately structural rather
# than a list of known wrapper paths. A tmux SERVER binary is never a shell
# script; anything that is one is, by construction, a shim that gets to
# rewrite argv or the environment before the real binary sees them. Naming
# the shims instead re-opens the hole the moment a new one appears — which is
# precisely `#1033` (a second tmuxwrap copy) and `#755` (ghwrap picking by
# identity). Measured on this host, THREE distinct `tmux` scripts sit on an
# agent's PATH ahead of the real binary, and only one of them is ours:
#
#   monitor/tmuxwrap/tmux            nexus board-lethal-kill guard
#   $CCH_DIR/.bin/tmux               this harness's own socket shadow
#   .../agent-sandbox/bin/tmux       sandbox shim, injects `-f <sandbox.conf>`
#
# That last one is why "not a NEXUS wrapper" was not enough: it carries no
# nexus marker, answers `-V` as tmux 2.6, and would have been selected — then
# silently injected its own config file into a harness that passes
# `-f /dev/null` specifically to run config-free.
_cch_is_script() {
    local magic
    IFS= read -r -N 2 magic < "$1" 2>/dev/null || return 1
    [[ "$magic" == '#!' ]]
}

# Narrower companion: is $1 specifically a NEXUS PATH-front shim? Same
# structural predicate `monitor/tmuxwrap/tmux` applies to itself
# (`_tw_is_nexus_wrapper`) — marker token, or the wrapper's own path, within
# the first 40 lines. Sharing the predicate makes this file and the shim
# agree about what a shim IS by construction rather than by two
# hand-maintained lists that drift. Used only by the degraded fallback below.
_cch_is_path_front_shim() {
    local f="$1" line n=0
    _cch_is_script "$f" || return 1
    while (( n < 40 )) && IFS= read -r line; do
        case "$line" in
            *NEXUS-PATH-FRONT-WRAPPER-MARKER*) return 0 ;;
            *monitor/tmuxwrap/tmux*)           return 0 ;;
        esac
        n=$((n + 1))
    done < "$f"
    return 1
}

# Resolve the REAL tmux executable — by CAPABILITY, not by IDENTITY.
#
# This used to be `type -P tmux`, i.e. "the first thing on PATH called tmux",
# and on any nexus agent process that is `monitor/tmuxwrap/tmux` — the
# PATH-FRONT shim, force-fronted into every non-interactive bash by
# $BASH_ENV (monitor/shellenv/bash_env.sh). The shadow written below was
# therefore `exec .../monitor/tmuxwrap/tmux -L <socket> "$@"`, whose body
# contains the literal string `monitor/tmuxwrap/tmux` — which is exactly what
# the shim's own `_tw_is_nexus_wrapper` gate matches. So the shim classified
# the harness's OWN injector as "another wrapper", skipped it, and resolved
# past it to a real tmux with NO `-L` at all. With `$TMUX` set (the harness
# runs inside a production pane) that lands on the PRODUCTION SOCKET
# (your-org/nexus-code#1042 A).
#
# "The first PATH hit that is not me" is an identity test and it is a known
# defect class here: ghwrap chose a 2021 client over an installed modern one
# (`#755`), and two tmuxwrap copies each elected the other as "the real tmux"
# (`#1033`). Excluding one path BY NAME re-opens the moment a second copy
# exists. So both gates below are PROPERTIES:
#
#   (1) not a PATH-front shim  — structural, shared with the shim itself;
#   (2) it BEHAVES like tmux   — `-V` reports a tmux version.
#
# Neither gate alone is sufficient, and that is worth stating: a shim that
# passes calls through ALSO answers `-V` correctly, so capability cannot see a
# transparent proxy; and a non-shim candidate can still be some unrelated
# `tmux` on PATH, which capability is what rejects.
#
# `type -P`-style PATH walking (not `command -v`) so a shell alias/function
# never answers: the agent-sandbox ships an aliased `tmux='tmux -2'`.
#
# Memoised through the ENVIRONMENT, not through a shell global, and the
# distinction is the whole point (skeptic F4). Nearly every call site is
# `$(_cch_real_tmux)` — a SUBSHELL — so an assignment made inside the function
# dies with it and the parent's copy stays empty. Measured: it did. The memo
# therefore only works if some caller EXPORTS it, which cch_setup now does
# after its own resolution; subshells then inherit it and neither re-walk PATH
# nor fork `-V`. A caller that bypasses cch_setup (the isolation suite itself)
# simply pays the walk each time, which is correct but not free.
_CCH_REAL_TMUX="${_CCH_REAL_TMUX:-}"
_cch_real_tmux() {
    [[ -n "$_CCH_REAL_TMUX" ]] && { printf '%s' "$_CCH_REAL_TMUX"; return 0; }
    local c d ifs_save
    local -a cands=()
    ifs_save="$IFS"; IFS=:
    for d in ${PATH:-}; do
        [[ -n "$d" ]] && cands+=("$d/tmux")
    done
    IFS="$ifs_save"
    cands+=(/usr/bin/tmux /usr/local/bin/tmux)

    # Tier 1 — a NON-SCRIPT that answers `-V` as tmux. The `#!` test is a
    # cheap builtin read, so `-V` only ever forks for a plausible candidate.
    for c in "${cands[@]}"; do
        [[ -x "$c" && ! -d "$c" ]] || continue
        _cch_is_script "$c" && continue
        [[ "$("$c" -V 2>/dev/null)" == tmux\ * ]] || continue
        _CCH_REAL_TMUX="$c"
        printf '%s' "$c"
        return 0
    done

    # Tier 2 — DEGRADED. No real binary anywhere: some hosts legitimately
    # ship tmux as a wrapper script (Nix, some brew layouts). Take a
    # non-nexus script rather than skipping the whole suite, but SAY SO —
    # a silent downgrade here is how a harness ends up running against
    # somebody else's injected config.
    for c in "${cands[@]}"; do
        [[ -x "$c" && ! -d "$c" ]] || continue
        _cch_is_path_front_shim "$c" && continue
        [[ "$("$c" -V 2>/dev/null)" == tmux\ * ]] || continue
        echo "cc-harness: WARNING — no real tmux binary on PATH; falling back to the script $c" >&2
        _CCH_REAL_TMUX="$c"
        printf '%s' "$c"
        return 0
    done
    return 1
}

# Resolve the real python3.
_cch_python() {
    command -v python3 2>/dev/null || command -v python 2>/dev/null
}

# Skip-gate. Scenarios call this BEFORE cch_setup so the skip path is
# cheap. Gated on RUN_CC_HARNESS=1 (separate axis from RUN_INTEGRATION,
# since this suite additionally needs node + a real claude binary).
#
# Exit code: 0 normally (so the fast-loop runner monitor/watcher/
# run-tests.sh — which counts rc==0 as PASS — treats a self-skip as a
# clean non-failure, matching SLOW_TESTS / RUN_INTEGRATION). BUT under the
# pre-update gate (CCH_GATE=1) a skip is NOT benign: it means the gate
# could not actually validate the candidate, so it must NOT be confused
# with a pass. There we exit 77 (the autotools "SKIP" sentinel) so
# gate.sh can fail RED on any skip — the exact green-via-skip hole B12
# closes (your-org/your-nexus#236 U12). 77 is unused by these scenarios'
# real pass/fail paths.
cch_skip_if_disabled() {
    local why=""
    if [[ "${RUN_CC_HARNESS:-0}" != "1" ]]; then
        why="set RUN_CC_HARNESS=1 to enable"
    elif ! _cch_real_tmux >/dev/null; then
        why="tmux not on PATH"
    elif ! command -v node >/dev/null 2>&1; then
        why="node not on PATH"
    elif ! _cch_python >/dev/null; then
        why="python3 not on PATH"
    elif ! cch_resolve_claude >/dev/null 2>&1; then
        why="no claude binary (run monitor/install-claude-local.sh, or set CLAUDE_BIN)"
    fi
    if [[ -n "$why" ]]; then
        echo "skipped: $(basename "${0}") ($why)"
        # Exit 77 = SKIP (your-org/nexus-code#568 A6). This used to exit 0
        # unless `CCH_GATE=1`, so under the canonical full-suite recipe all six
        # `test-realmodel-*.sh` recorded **PASS in ~0.2 s** having asserted
        # nothing — in the one band whose entire purpose is catching renderer
        # drift against the real binary. A green ledger row for a test that
        # declined to run is worse than a red one: it is a coverage claim the
        # suite cannot support, and it is exactly the defect A6 exists to
        # remove. `CCH_GATE` no longer changes the exit code, only whether the
        # caller treats a skip as fatal.
        exit 77
    fi
}

# Resolve the claude binary. Honors CLAUDE_BIN (the pre-update gate sets
# this to a candidate-version install in a throwaway prefix); else the
# project-local install. Echoes the path; rc=1 if none found.
cch_resolve_claude() {
    if [[ -n "${CLAUDE_BIN:-}" ]] && [[ -x "$CLAUDE_BIN" ]]; then
        printf '%s' "$CLAUDE_BIN"; return 0
    fi
    local local_bin="$CCH_REPO_ROOT/node_modules/.bin/claude"
    if [[ -x "$local_bin" ]]; then
        printf '%s' "$local_bin"; return 0
    fi
    return 1
}

# cch_stage_candidate <version> [<prefix>] — install a CANDIDATE claude into a
# PRIVATE prefix and print the resulting binary path on stdout.
#
# THE ONE ROOT-RESOLUTION-IMMUNE INSTALL (your-org/nexus-code#1002). gate.sh
# and any ad-hoc probe that needs a candidate binary in hand both go through
# here, so the form cannot drift between them. The form is
#
#     npm install --prefix <prefix> --no-save @anthropic-ai/claude-code@<v>
#
# and `--prefix` is the whole safety: without it npm resolves its root by
# WALKING UP from the cwd to the nearest package.json, which from anywhere
# under the nexus is the nexus root's — so `cd <dir> && npm install …` in a
# package.json-less <dir> installs the candidate into the LIVE node_modules,
# prints `changed 2 packages`, exits 0, and (under --no-save) leaves
# `git status` clean. Measured 2026-08-25: a gate-RED 2.1.245 sat in the live
# tree for ~25 s, inside a ~37 s window in which `node_modules/.bin/claude`
# was twice absent altogether; every spawn resolves that path fresh.
#
# VERIFIED, NOT ASSUMED. A mis-rooted install has two visible shapes at the
# caller — no binary under the prefix (it went elsewhere), or a binary that is
# not the candidate (the prefix already held something) — and each is refused
# with its own code, so a 0 from here means the printed path IS the candidate.
# NOTHING is printed on stdout on any refusal: a caller doing
# `CLAUDE_BIN=$(cch_stage_candidate …)` must never receive a path it should
# not export. npm's own output goes to stderr for the same reason.
#
# Exit: 0 path printed; 2 usage (no/ill-formed version, or a prefix that IS
#       the nexus root or its node_modules — the live tree is never a staging
#       target); 3 the install produced no executable at
#       <prefix>/node_modules/.bin/claude; 4 that binary does not report
#       <version>; 5 npm missing, mktemp failed, or the install itself failed
#       (npm's diagnostics precede this).
#
# npm cache: an operator-set npm_config_cache / NPM_CONFIG_CACHE is honoured;
# otherwise a cache INSIDE the prefix, so the stage is self-contained and never
# touches $HOME/.npm (read-only on sandboxed hosts, your-org/nexus-code#325).
# Passed on the command line, never exported: this function is sourced into
# the caller's shell and must not change its environment.
cch_stage_candidate() {
    local version="${1:-}" prefix="${2:-}"
    local pkg="${CCH_STAGE_PACKAGE:-@anthropic-ai/claude-code}"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'cch_stage_candidate: a version X.Y.Z is required (got %q)\n' "$version" >&2
        return 2
    fi
    if [[ -z "$prefix" ]]; then
        prefix=$(mktemp -d -t cc-stage-XXXXXX) \
            || { echo "cch_stage_candidate: mktemp failed (TMPDIR=${TMPDIR:-unset})" >&2; return 5; }
    fi
    # Canonicalise WITHOUT creating anything: the refusal below must not leave
    # an empty `node_modules/` behind in the live tree as its own side effect
    # (measured — a `mkdir -p` ahead of the check did exactly that).
    local abs_prefix abs_root
    abs_prefix=$(readlink -m -- "$prefix") || return 2
    abs_root=$(readlink -m -- "$CCH_REPO_ROOT") || abs_root="$CCH_REPO_ROOT"
    if [[ "$abs_prefix" == "$abs_root" || "$abs_prefix" == "$abs_root/node_modules" ]]; then
        printf 'cch_stage_candidate: REFUSED — prefix %s is the live nexus tree; a candidate is never staged into it (your-org/nexus-code#1002)\n' "$abs_prefix" >&2
        return 2
    fi
    mkdir -p "$abs_prefix" 2>/dev/null \
        || { printf 'cch_stage_candidate: cannot create prefix %s\n' "$abs_prefix" >&2; return 2; }
    command -v npm >/dev/null 2>&1 \
        || { echo "cch_stage_candidate: npm not on PATH" >&2; return 5; }
    local cache="${npm_config_cache:-${NPM_CONFIG_CACHE:-$abs_prefix/.npm-cache}}"
    mkdir -p "$cache" 2>/dev/null \
        || { printf 'cch_stage_candidate: cannot create npm cache dir %s (set npm_config_cache to a writable path)\n' "$cache" >&2; return 5; }
    echo "cch_stage_candidate: npm install --prefix $abs_prefix --no-save $pkg@$version" >&2
    if ! npm_config_cache="$cache" npm install --prefix "$abs_prefix" --no-save "$pkg@$version" --loglevel=http >&2; then
        echo "cch_stage_candidate: candidate install FAILED (npm's output is above)" >&2
        return 5
    fi
    local bin="$abs_prefix/node_modules/.bin/claude" got=""
    if [[ ! -x "$bin" ]]; then
        printf 'cch_stage_candidate: REFUSED — the install produced no executable at %s. npm resolved a root other than the prefix (the your-org/nexus-code#1002 shape): check the LIVE node_modules before anything else.\n' "$bin" >&2
        return 3
    fi
    got=$("$bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ "$got" != "$version" ]]; then
        printf 'cch_stage_candidate: REFUSED — %s reports %q, not the requested %s; not printing it as the candidate.\n' "$bin" "${got:-<nothing>}" "$version" >&2
        return 4
    fi
    printf '%s\n' "$bin"
}

# Write $CCH_CFG/settings.json — the isolated USER-SCOPE settings file, the
# same scope a production nexus agent reads its own from. Called by cch_setup,
# and callable again by a scenario that needs to re-seed BETWEEN boots (see
# the migration hazard below, which makes hand-rolling that rewrite unsafe).
#
#   $1 / CCH_EDITOR_MODE  keyboard mode. UNSET defaults to `vim`; the EMPTY
#                         string writes no key (the binary's own default).
#   CCH_TUI               rendering mode. unset/empty writes no key.
#
# --- editorMode: production parity (your-org/nexus-code#724) --------------
# Every production nexus agent inherits `editorMode: "vim"` from user scope.
# Measured on the operator's live config: the key is present BOTH in
# `$CLAUDE_CONFIG_DIR/settings.json` and in `$CLAUDE_CONFIG_DIR/.claude.json`,
# and either one ALONE is sufficient — booted against 2.1.224, `-- INSERT --`
# renders from a settings.json-only seed and from a .claude.json-only seed
# alike, and from neither when neither is present. So the harness reproduces
# it by the same route the operator declares it (settings.json), not by a
# route that merely happens to work.
#
# Seeding nothing — what this harness did until #724 — boots the real binary
# in the DEFAULT keyboard mode, so the gate validates a mode nobody runs. Same
# class as the `tui` fix in #568. It matters concretely rather than
# cosmetically: vim mode paints `-- INSERT --` into the status row, and
# pane-state.sh's `_detect_vim_insert` reads exactly that row to decide
# `user-typing` vs `idle` (#603/#626) — i.e. the production keyboard mode is
# an INPUT to the classification this whole harness exists to gate.
#
# --- skipDangerousModePermissionPrompt: NOT optional, and not cosmetic ----
# The real binary MIGRATES `.claude.json`'s `bypassPermissionsModeAccepted`
# into settings.json under this name on first boot, and DELETES the original
# key (measured on 2.1.224: `.claude.json` comes back with the key `null`,
# settings.json comes back holding `skipDangerousModePermissionPrompt: true`).
# So after any boot the ONLY thing suppressing the Bypass Permissions warning
# lives in settings.json. A scenario that rewrites settings.json between boots
# without re-supplying it wedges the NEXT boot on that modal dialog forever.
# That used to report `state=empty` — "don't know yet" — so it read as a
# timeout rather than as a config error; since your-org/nexus-code#768
# pane-state.sh recognises the modal and reports `state=blocked
# overlay=bypass-permissions`, so the wedge now names itself. The naming is a
# diagnostic, NOT a substitute for this line: a named wedge is still a wedge,
# and re-supplying the key is what prevents it. Writing it unconditionally here
# makes the harness's own re-seed path safe, which is what lets the #724
# scenario boot a seeded worker and an unseeded control in one run.
cch_write_settings() {
    local editor="${1-${CCH_EDITOR_MODE-vim}}"
    local -a keys=('"skipDangerousModePermissionPrompt": true')
    [[ -n "${CCH_TUI:-}" ]] && keys+=("\"tui\": \"$CCH_TUI\"")
    [[ -n "$editor" ]]      && keys+=("\"editorMode\": \"$editor\"")
    local IFS=,
    printf '{%s}\n' "${keys[*]}" > "$CCH_CFG/settings.json"
}

# Bring up the run: tmpdir, mock backend, isolated config + tmux socket.
cch_setup() {
    CLAUDE_BIN=$(cch_resolve_claude) || { echo "cch_setup: no claude binary" >&2; return 1; }
    export CLAUDE_BIN

    CCH_DIR=$(mktemp -d -t cc-harness-XXXXXX)
    CCH_CFG="$CCH_DIR/cfg"
    CCH_WORKDIR="$CCH_DIR/proj"
    CCH_STATE_DIR="$CCH_DIR/state"
    CCH_CONTROL="$CCH_DIR/control.json"
    CCH_LOG="$CCH_DIR/requests.log"
    # ISOLATION IS BY DIRECTORY, NOT BY PATH ORDERING (your-org/nexus-code#1042 A).
    #
    # The harness used to isolate itself with a unique `-L cch-$$-$RANDOM`
    # socket injected by a PATH shadow. That is a PATH-ordering bet, and the
    # harness LOSES it: pane-state.sh is a `#!/usr/bin/env bash` script, so
    # every invocation sources $BASH_ENV, which force-fronts
    # monitor/tmuxwrap AHEAD of the shadow. The shadow's CONTENTS were never
    # even consulted — see _cch_real_tmux above for how that reached
    # production.
    #
    # TMUX_TMPDIR cannot be demoted by a PATH shim: EVERY tmux binary,
    # wrapper or real, computes its socket path from it. That is the whole
    # reason to move the boundary here — it is a property of the environment,
    # not of who wins a race on PATH.
    #
    # Measured on this host (tmux 2.6), and the reason `env -u TMUX` is not
    # optional — $TMUX OVERRIDES TMUX_TMPDIR, and the harness always runs
    # inside a production pane, where $TMUX is always set:
    #   $TMUX set   + TMUX_TMPDIR set + bare tmux -> PRODUCTION socket
    #   $TMUX unset + TMUX_TMPDIR set + bare tmux -> $TMUX_TMPDIR, cannot see production
    #   explicit -L                                -> wins over $TMUX
    #
    # The socket keeps a UNIQUE name. Naming it `default` would make every
    # call site read `-L default`, which is indistinguishable from a call on
    # the operator's own server — `lint-no-tmux-server-kill.sh` rule4 rejects
    # exactly that, unexemptably, and it is right to: an isolation that is
    # invisible at the call site and rests on ambient state is the shape of
    # the defect this whole change exists to remove. cch_setup instead
    # symlinks `default` to it INSIDE the private tmpdir once the server is
    # up (see below) — so the bare `tmux` calls inside pane-state.sh, which
    # the harness cannot pass flags to, still land here.
    CCH_TMUX_TMPDIR="$CCH_DIR/tmuxtmp"
    CCH_SOCKET="cch-$$-$RANDOM"
    CCH_SESSION="cch-$$-$RANDOM"
    mkdir -p "$CCH_CFG" "$CCH_WORKDIR" "$CCH_STATE_DIR" "$CCH_DIR/.bin" \
             "$CCH_TMUX_TMPDIR"
    chmod 700 "$CCH_TMUX_TMPDIR"

    # THE SOCKET PATH MUST BE ADDRESSABLE (your-org/nexus-code#991).
    #
    # `CCH_DIR` comes from `mktemp -d -t`, i.e. from `$TMPDIR`, and an agent's
    # `$TMPDIR` is its session scratchpad — ~124 bytes here. Adding
    # `/cc-harness-XXXXXX/tmuxtmp/tmux-<uid>/cch-<pid>-<rand>` puts the socket
    # path near 185 bytes against a `sun_path` that holds 107. Every tmux call
    # then dies `File name too long`, the harness takes its "tmux unavailable"
    # branch, and NINE cch-realmodel suites reported FAIL over ZERO assertions —
    # an environment fault presenting as a defect in the code under test.
    #
    # Checked HERE rather than at each call site because this is the line that
    # DECIDES the path; a check anywhere downstream is a check on a value
    # somebody already committed to.
    # FAIL CLOSED on an unreachable library, rather than skipping the check.
    # `[[ -r … ]] && check` reads as caution and behaves as "no check ran",
    # which is indistinguishable downstream from "the path fits" — the shape
    # this whole change exists to remove.
    if [[ ! -r "$_cch_self_dir/../_tmux_socket.sh" ]]; then
        echo "cch_setup: REFUSING — $_cch_self_dir/../_tmux_socket.sh is unreachable," >&2
        echo "  so the socket path cannot be measured. A check that did not run is not a pass." >&2
        return 1
    fi
    . "$_cch_self_dir/../_tmux_socket.sh"
    if ! _cch_sock_verdict=$(tmux_socket_verdict "$CCH_SOCKET" "$CCH_TMUX_TMPDIR"); then
        {
            echo "cch_setup: REFUSING — the private tmux socket path does not fit."
            echo "  ${_cch_sock_verdict}"
            echo "  sun_path is 108 bytes; 107 is the most a NUL-terminating caller can"
            echo "  bind. (108 binds with a full-struct addrlen; nothing here does that.)"
            echo "  CCH_DIR comes from \$TMPDIR (mktemp -d -t); yours is:"
            echo "    TMPDIR=${TMPDIR:-<unset>}"
            echo "  This is NOT a failure of the code under test — no tmux call was made."
            echo "  Remedy: TMPDIR=$(tmux_socket_short_tmpdir "cch") (mkdir it first),"
            echo "  or run from a shorter scratch root. your-org/nexus-code#991."
        } >&2
        return 1
    fi

    # Pre-seed config so the real binary skips ALL first-run gates:
    #   theme picker -> theme + hasCompletedOnboarding
    #   folder trust -> per-project projects.<cwd>.hasTrustDialogAccepted
    # (custom-API-key dialog is avoided by using ANTHROPIC_AUTH_TOKEN
    # rather than ANTHROPIC_API_KEY — see cch_boot_worker.)
    #
    # NOTE — EDITOR MODE (load-bearing for GUIDE surface 2c). THIS BLOCK
    # WRITES `.claude.json` AND CARRIES NO `editorMode` KEY — but the mode is
    # no longer unset by the time a pane boots: `cch_write_settings` below
    # seeds `editorMode` into `settings.json`, defaulting to **`vim`**
    # (`${CCH_EDITOR_MODE-vim}`), which is what production runs (#724). So
    # panes booted here come up in VI mode unless a scenario overrides
    # `CCH_EDITOR_MODE`.
    #
    # This paragraph used to end "so every pane comes up in DEFAULT (emacs)
    # mode", and that sentence survived a textually-clean merge of #724's
    # seeding onto this branch while becoming false — the exact
    # harness-boots-emacs premise the 2c thread spent two rounds correcting.
    # Restated rather than deleted, because the HISTORY is still the point:
    # while the mode really was unset, a probe prefixing its paste with the
    # production VI-insert keys (`send-keys i BSpace`) was a NET NO-OP — it
    # typed `i` and deleted it — and so could not distinguish "VI-insert
    # hardening works" from "absent". Two rounds (2.1.216, 2.1.222)
    # mislabelled such a probe `empirical`; the second was disproven by
    # differential control (dropping the prefix left it passing
    # identically). The standing rule is unchanged and now has teeth: never
    # ASSUME the mode — set it explicitly and assert the `-- INSERT --` /
    # `-- NORMAL --` indicator actually renders. That is what
    # test-realmodel-vimode.sh does, in three arms (seeded `vim` => present;
    # no key => absent; out-of-enum `vi` => absent, because the setting is a
    # two-member enum `["normal","vim"]` carrying `.catch(void 0)`).
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg wd "$CCH_WORKDIR" '{
            theme: "dark", hasCompletedOnboarding: true,
            bypassPermissionsModeAccepted: true,
            projects: { ($wd): {
                hasTrustDialogAccepted: true,
                hasCompletedProjectOnboarding: true, allowedTools: [] } }
        }' > "$CCH_CFG/.claude.json"
    else
        printf '{"theme":"dark","hasCompletedOnboarding":true,"bypassPermissionsModeAccepted":true,"projects":{"%s":{"hasTrustDialogAccepted":true,"hasCompletedProjectOnboarding":true,"allowedTools":[]}}}\n' \
            "$CCH_WORKDIR" > "$CCH_CFG/.claude.json"
    fi

    cch_write_settings

    # Default control directive: single-shot canned text.
    cch_control '{"mode":"text","text":"MOCK_OK_HELLO"}'

    # Start the mock on an ephemeral port; discover what it bound.
    local py; py=$(_cch_python)
    local port_file="$CCH_DIR/mock.port"
    MOCK_DIR="$CCH_DIR" MOCK_LOG="$CCH_LOG" MOCK_CONTROL="$CCH_CONTROL" \
        MOCK_PORT_FILE="$port_file" \
        "$py" "$CCH_MOCK_PY" 0 >"$CCH_DIR/mock.stderr" 2>&1 &
    CCH_MOCK_PID=$!
    local waited=0
    while [[ ! -s "$port_file" ]]; do
        sleep 0.1; waited=$((waited+1))
        if (( waited > 50 )); then
            echo "cch_setup: mock backend never advertised a port" >&2
            cat "$CCH_DIR/mock.stderr" >&2 || true
            return 1
        fi
        kill -0 "$CCH_MOCK_PID" 2>/dev/null || {
            echo "cch_setup: mock backend died on startup" >&2
            cat "$CCH_DIR/mock.stderr" >&2 || true
            return 1
        }
    done
    CCH_MOCK_PORT=$(<"$port_file")

    # PATH-shadow tmux wrapper. DEFENCE IN DEPTH ONLY — it is NOT the
    # isolation mechanism any more, and must never be treated as one:
    # $BASH_ENV force-fronts monitor/tmuxwrap ahead of it in every
    # non-interactive bash, so on an agent process it is simply not reached.
    # TMUX_TMPDIR (above) is what actually pins the socket. This exists for
    # the case where it IS reached first — a caller with no $BASH_ENV — and
    # it pins the SAME socket, so the two routes agree rather than compete.
    #
    # It carries the shim marker so _cch_is_path_front_shim and tmuxwrap's
    # _tw_is_nexus_wrapper both recognise it as a shim by PROPERTY. Note the
    # marker is why tmuxwrap will not delegate to it — which is correct now
    # and was the whole bug before, when this file depended on exactly that
    # delegation without saying so.
    local real_tmux
    real_tmux=$(_cch_real_tmux) || {
        echo "cch_setup: no real tmux binary found (only PATH-front shims)" >&2
        return 1
    }
    # Export so the memo actually reaches the command-substitution subshells
    # every later cch_tmux uses — see the note on _CCH_REAL_TMUX above.
    export _CCH_REAL_TMUX="$real_tmux"
    CCH_TMUXWRAP="$CCH_DIR/.bin/tmux"
    printf '#!/usr/bin/env bash\n# NEXUS-PATH-FRONT-WRAPPER-MARKER — cc-harness socket shadow, never "the real tmux".\nexec %q -L %q "$@"\n' \
        "$real_tmux" "$CCH_SOCKET" > "$CCH_TMUXWRAP"
    chmod +x "$CCH_TMUXWRAP"

    # Bring up the isolated server with a detached scratch window. -f
    # /dev/null ignores the operator's personal tmux.conf.
    cch_tmux -f /dev/null new-session -d -s "$CCH_SESSION" \
        -x 120 -y 40 -c "$CCH_WORKDIR" 'sleep 36000'

    # Alias the DEFAULT socket name to ours, inside the private tmpdir.
    #
    # This is the seam for the calls the harness does not control:
    # monitor/pane-state.sh invokes `tmux` BARE, so it can be given an
    # environment but never a flag. With TMUX_TMPDIR pinned and $TMUX
    # stripped, a bare call resolves to <tmpdir>/tmux-$UID/default — and this
    # symlink is what makes that path our server rather than a dead end.
    # connect(2) resolves symlinks, so the client lands on the real socket
    # (verified on tmux 2.6, the version on this host).
    #
    # Note what this is NOT: it is not a `-L default` pin. The name `default`
    # appears only as a link inside a directory no other process can reach,
    # never as an argument at a call site, so every tmux call in this file
    # still names a socket that is provably ours.
    local _cch_sockdir="$CCH_TMUX_TMPDIR/tmux-$(id -u)"
    if [[ -S "$_cch_sockdir/$CCH_SOCKET" ]]; then
        ln -sfn "$CCH_SOCKET" "$_cch_sockdir/default" 2>/dev/null || true
    else
        echo "cch_setup: harness socket missing at $_cch_sockdir/$CCH_SOCKET" >&2
        return 1
    fi

    export CCH_DIR CCH_CFG CCH_WORKDIR CCH_STATE_DIR CCH_CONTROL CCH_LOG \
           CCH_SOCKET CCH_SESSION CCH_MOCK_PORT CCH_MOCK_PID CCH_TMUXWRAP \
           CCH_TMUX_TMPDIR

    trap cch_teardown EXIT
}

cch_teardown() {
    if [[ -n "${CCH_TMUXWRAP:-}" && -x "${CCH_TMUXWRAP:-}" ]]; then
        cch_tmux kill-server 2>/dev/null || true   # tmux-scoped: cch_tmux() pins -L "$CCH_SOCKET" (this file)
    fi
    if [[ -n "${CCH_MOCK_PID:-}" ]]; then
        kill "$CCH_MOCK_PID" 2>/dev/null || true
    fi
    if [[ -n "${CCH_DIR:-}" && -d "${CCH_DIR:-}" ]]; then
        # Move the run dir aside (rename) instead of rm: the killed claude
        # may still be releasing its config dir, and over NFS unlink would
        # silly-rename open files to `.nfs*` and make rm report "Directory
        # not empty". A same-fs rename always succeeds regardless of holders;
        # the entry is reaped later by `_trash.sh --clear`. Fall back to the
        # old settle+retry rm if trashing is unavailable.
        trash_path "$CCH_DIR" >/dev/null 2>&1 \
            || { sleep 0.3; rm -rf "$CCH_DIR" 2>/dev/null \
                || { sleep 0.7; rm -rf "$CCH_DIR" 2>/dev/null || true; }; }
    fi
}

# Socket-scoped tmux. THREE independent pins, deliberately redundant:
#   * a real binary (never a PATH-front shim)          — _cch_real_tmux
#   * `env -u TMUX`   so the ambient production pane's $TMUX cannot win
#   * TMUX_TMPDIR + -L so the socket PATH is fully determined by the env
# Drop any one and the remaining two still cannot reach the live server.
cch_tmux() {
    local real_tmux
    real_tmux=$(_cch_real_tmux) || {
        echo "cch_tmux: no real tmux binary found (only PATH-front shims)" >&2
        return 127
    }
    # FAIL CLOSED on an unset boundary. An empty TMUX_TMPDIR is not "no
    # preference" — tmux falls back to /tmp/tmux-$UID, which is the LIVE
    # server's directory, so the one situation where this function does not
    # know where it is pointing is the one where it must not run. Reachable if
    # a caller invokes cch_tmux before cch_setup, or after a setup that failed
    # partway; cheap to check, unrecoverable to get wrong.
    if [[ -z "${CCH_TMUX_TMPDIR:-}" ]]; then
        echo "cch_tmux: refusing — CCH_TMUX_TMPDIR is unset (cch_setup not run?)" >&2
        return 78
    fi
    env -u TMUX TMUX_TMPDIR="$CCH_TMUX_TMPDIR" \
        "$real_tmux" -L "$CCH_SOCKET" "$@"
}

# Run a shell FUNCTION (or any command) under the harness's tmux binding.
#
# `env -u TMUX …` is the right tool for an EXTERNAL command, but `env` execs a
# program and cannot run a shell function — and the watcher's own functions
# (`_over_limit_process_wakes`, which resolves a tmux window index) are exactly
# the things a scenario needs to drive in-process. Without this they inherit
# the ambient $TMUX and probe the PRODUCTION server, where the harness window
# does not exist; the probe then reports the window ABSENT, which the state
# machine reads as a legitimate answer rather than as a failure to look
# (your-org/nexus-code#1042 A; test-realmodel-overlimit phase D).
#
# The binding is applied in a SUBSHELL, so effects that land on DISK survive
# and in-memory variable changes do not. Every current caller drives a
# file-backed state machine, which is why that is the right trade — check it
# still holds before adding a caller that expects a variable back.
cch_with_tmux_env() (
    if [[ -z "${CCH_TMUX_TMPDIR:-}" ]]; then
        echo "cch_with_tmux_env: refusing — CCH_TMUX_TMPDIR is unset" >&2
        return 78          # same fail-closed reasoning as cch_tmux
    fi
    unset TMUX
    export TMUX_TMPDIR="$CCH_TMUX_TMPDIR"
    export PATH="$CCH_DIR/.bin:$PATH"
    "$@"
)

# Write a control directive (JSON string) for the mock's NEXT request.
cch_control() {
    printf '%s\n' "$1" > "$CCH_CONTROL"
}

# Boot the real claude in a new tmux window against the mock. Echoes the
# new window's index.
#
# By DEFAULT this is the renderer path: no `--settings`, so no hooks are
# wired and the scenario exercises pane-state's renderer classification
# only. That default is why, for a long time, every gate scenario but
# test-realmodel-overlimit.sh ran hook-free — and why GUIDE surface 2d
# (hooks + settings) could never be cleared by the gate and fell back to
# source inspection every round.
#
# Two opt-in knobs close that hole without disturbing the renderer
# scenarios:
#
#   CCH_SETTINGS    path to a settings JSON passed as `--settings <path>`.
#                   Set it to wire real hooks (PreToolUse, PostToolUse,
#                   Notification, …) into the booted binary — see
#                   monitor/watcher/test-integration/test-realmodel-pretooluse-hook.sh.
#   CCH_EXTRA_ENV   extra `K=v` assignments spliced into the `env -i`
#                   line (e.g. NEXUS_ROOT / NEXUS_STATE_DIR so a real
#                   hook script writes into the harness tmpdir). The
#                   CALLER is responsible for shell-quoting values; keep
#                   them path-simple.
#
# Both default to empty, so existing scenarios boot BEHAVIOURALLY
# identically — same argv, same env, no --settings — but NOT
# byte-identically: with CCH_EXTRA_ENV empty the `%s` splice leaves one
# extra space in the launch line. Measured: delta is exactly 1 byte, and
# the two strings are identical once spaces are removed, so the token
# sequence the shell parses is unchanged. Stating the measured fact rather
# than rounding it up to "byte-identical".
cch_boot_worker() {
    local name="$1"
    # env -i for a hermetic child: only the vars claude needs. PATH must
    # carry node (claude is a node program) — pass the harness PATH
    # through. ANTHROPIC_AUTH_TOKEN (bearer) instead of ANTHROPIC_API_KEY
    # avoids the interactive custom-API-key approval dialog.
    local settings_arg=""
    if [[ -n "${CCH_SETTINGS:-}" ]]; then
        printf -v settings_arg ' --settings %q' "$CCH_SETTINGS"
    fi
    # CCH_CLAUDE_ARGS: extra `claude` flags spliced verbatim after
    # `--dangerously-skip-permissions` — the third opt-in knob, added for
    # `--plugin-dir <dir>` so the longjob-watch dispatcher plugin
    # (your-org/nexus-code#1535) can be booted against the mock and its
    # events COUNTED as API requests. The CALLER shell-quotes; empty leaves
    # the launch line token-identical to before.
    if [[ -n "${CCH_CLAUDE_ARGS:-}" ]]; then
        settings_arg="$settings_arg ${CCH_CLAUDE_ARGS}"
    fi
    local launch
    # TMUX_TMPDIR is passed through the `env -i` wall on purpose. `env -i`
    # strips $TMUX, which tmux had set for this pane, so anything the pane
    # runs that shells out to tmux — a hook calling pane-state.sh, say —
    # would otherwise compute the DEFAULT socket dir and land on production.
    printf -v launch 'env -i HOME=%q PATH=%q CLAUDE_CONFIG_DIR=%q \
TMUX_TMPDIR=%q ANTHROPIC_BASE_URL=%q ANTHROPIC_AUTH_TOKEN=mock-token \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 \
DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 \
%s TERM=%q %q --dangerously-skip-permissions%s' \
        "$CCH_CFG" "$PATH" "$CCH_CFG" "$CCH_TMUX_TMPDIR" \
        "http://127.0.0.1:$CCH_MOCK_PORT" "${CCH_EXTRA_ENV:-}" \
        "${TERM:-xterm-256color}" "$CLAUDE_BIN" "$settings_arg"

    cch_tmux new-window -d -t "$CCH_SESSION": -n "$name" -c "$CCH_WORKDIR" "$launch"
    local idx
    idx=$(cch_tmux list-windows -t "$CCH_SESSION" -F '#{window_name} #{window_index}' \
        | awk -v n="$name" '$1==n {print $2; exit}')
    # remain-on-exit keeps the dead pane (and its last frame) around after
    # the inner REPL exits, so pane-state's process-liveness gate can
    # emit `absent` instead of the window vanishing — mirrors how the
    # production watcher configures worker windows.
    [[ -n "$idx" ]] && cch_tmux set-option -t "$CCH_SESSION:$idx" -w remain-on-exit on 2>/dev/null
    printf '%s' "$idx"
}

# Run the production pane-state.sh against a live window via the wrapper.
#
#   cch_pane_state <window-index> [extra pane-state.sh flags…]
#
# TWO SEAMS, both added because their absence is what a caller re-rolled this
# function's body to work around — and the re-rolled copy did not carry the
# socket pins, so it queried the PRODUCTION server and came back empty
# (your-org/nexus-code#1042 A; test-realmodel-overlimit phase B):
#
#   * extra flags are forwarded BEFORE the window key, which is the argument
#     order pane-state.sh expects;
#   * $CCH_PANE_STATE_DIR overrides NEXUS_STATE_DIR for callers that point
#     pane-state at a synthetic nexus root.
#
# If you need a variation this does not offer, ADD IT HERE. A second copy of
# these three env pins is a second place for them to fall out of date, and
# they are the only thing standing between this harness and the live board.
cch_pane_state() {
    local window="$1"; shift || true
    # `env -u TMUX` + TMUX_TMPDIR are the load-bearing pins: pane-state.sh
    # calls tmux BARE, and re-fronts monitor/tmuxwrap over the PATH shadow
    # below the moment its bash sources $BASH_ENV. Without these two, the
    # bare call resolves to the ambient $TMUX — the PRODUCTION socket
    # (your-org/nexus-code#1042 A). The PATH entry stays as a third pin.
    if [[ -z "${CCH_TMUX_TMPDIR:-}" ]]; then
        echo "cch_pane_state: refusing — CCH_TMUX_TMPDIR is unset" >&2
        return 78          # same fail-closed reasoning as cch_tmux
    fi
    env -u TMUX TMUX_TMPDIR="$CCH_TMUX_TMPDIR" \
        PATH="$CCH_DIR/.bin:$PATH" \
        NEXUS_STATE_DIR="${CCH_PANE_STATE_DIR:-$CCH_STATE_DIR}" \
        "$CCH_PANE_STATE" "$@" "$CCH_SESSION:$window"
}

# Convenience: just the state= token.
cch_state() {
    cch_pane_state "$1" | sed -n 's/.*state=\([^ ]*\).*/\1/p'
}

# Capture a window's pane (plain text, last 25 rows like pane-state).
cch_capture() {
    cch_tmux capture-pane -t "$CCH_SESSION:$1" -p -J -S -25 2>/dev/null
}

# Send a prompt the way the watcher injects: type the text, then Enter
# as a separate key (mirrors the send-keys paste-to-target path).
cch_send() {
    local window="$1" text="$2"
    cch_tmux send-keys -t "$CCH_SESSION:$window" "$text"
    sleep 0.4
    cch_tmux send-keys -t "$CCH_SESSION:$window" Enter
}

# Kill the inner claude process for a window (simulate a crash) so the
# pane goes to state=absent under remain-on-exit. PID-SCOPED ONLY: walks the
# pane shell's descendant tree by parent-PID and TERMs each node. NEVER use a
# cmdline-pattern kill (`pkill -f`) here — every nexus agent runs the SAME
# project-local claude binary inside ONE shared sandbox PID namespace, so a
# command-line match SIGTERMs the whole control plane at once (crash
# postmortem 2026-05-29; reports/nexus_2026-05-29_142117_crash-postmortem-pkill-mass-kill.md).
# lint-no-mass-kill.sh enforces this ban.
cch_kill_claude() {
    local window="$1" pane_pid
    pane_pid=$(cch_tmux display-message -p -t "$CCH_SESSION:$window" '#{pane_pid}' 2>/dev/null)
    [[ -n "$pane_pid" ]] || return 1
    _cch_kill_tree "$pane_pid"
}

# Collect a PID and all its descendants, leaves first, via `pgrep -P`
# (parent-PID) walks only — never by command-line pattern.
_cch_tree_pids() {
    local pid="$1" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        _cch_tree_pids "$child"
    done
    printf '%s\n' "$pid"
}

# TERM a PID subtree (leaves first), grant a short grace, then KILL any
# survivor. Scoped strictly to a one-shot snapshot of the subtree rooted
# at $1 — pid-scoped, never cmdline-matched (see cch_kill_claude above).
#
# The KILL escalation is load-bearing for the absent scenario: claude
# installs a graceful-shutdown SIGTERM handler, and on slow shared CI
# runners its teardown has been observed to outlive the scenario's 15 s
# `state=absent` window (cc-harness runs 26909460209 on dev and
# 27389919749 on PR 270 — identical flake signature on both sides of
# the #205 change; locally TERM→exit measures ~0.1 s). The scenario
# simulates a CRASH, so forcing the exit after a 2 s grace is faithful
# to the intent and removes the dependence on claude's teardown latency.
_cch_kill_tree() {
    local root="$1" pids pid alive i
    pids=$(_cch_tree_pids "$root")
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    for i in 1 2 3 4 5 6 7 8; do
        alive=0
        for pid in $pids; do
            kill -0 "$pid" 2>/dev/null && { alive=1; break; }
        done
        (( alive )) || return 0
        sleep 0.25
    done
    for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
}

# ---- polling predicates (mirrors _harness.sh) ----------------------------
wait_for() {
    local label="$1" max="$2"; shift 2
    [[ "$1" == "--" ]] || { echo "wait_for: missing -- separator" >&2; return 2; }
    shift
    local deadline=$(( $(date +%s) + max )) attempts=0
    while (( $(date +%s) < deadline )); do
        if "$@" >/dev/null 2>&1; then
            printf '  PASS: %s (after %d polls)\n' "$label" "$attempts"
            : "${PASS:=0}"; PASS=$(( PASS + 1 )); return 0
        fi
        attempts=$(( attempts + 1 )); sleep 0.25
    done
    printf '  FAIL: %s — predicate never satisfied within %ds (%d polls)\n' \
        "$label" "$max" "$attempts" >&2
    printf '         last cmd: %s\n' "$*" >&2
    # Say WHAT WAS SEEN, not merely that the wait expired. A bare timeout
    # invites "slow runner", which is the reading that cost your-org/
    # nexus-code#768 a probe run: the pane was wedged on the Bypass
    # Permissions modal the whole time, and nothing printed the state it was
    # actually in. Emitting the full pane-state line makes the diagnosis
    # available at the moment of failure — `state=blocked
    # overlay=bypass-permissions` reads very differently from `state=empty`.
    #
    # This runs ONLY on the failure path, so it cannot perturb a passing
    # scenario, and it is best-effort: a window that has gone away simply
    # yields nothing rather than turning a test failure into a harness error.
    if [[ "$1" == "cch_state_is" && -n "${2:-}" ]]; then
        local observed
        observed=$(cch_pane_state "$2" 2>/dev/null) || observed=""
        if [[ -n "$observed" ]]; then
            printf '         observed: %s\n' "$observed" >&2
            case "$observed" in
                *overlay=bypass-permissions*)
                    printf '         ^ the pane is wedged on the Bypass Permissions modal, NOT slow.\n' >&2
                    printf '           settings.json lost `skipDangerousModePermissionPrompt` between boots\n' >&2
                    printf '           (your-org/nexus-code#768) — re-seed it via cch_write_settings.\n' >&2
                    ;;
            esac
        fi
    fi
    : "${FAIL:=0}"; FAIL=$(( FAIL + 1 )); return 1
}

# Predicate helper: pane state equals expected.
cch_state_is() {
    [[ "$(cch_state "$1")" == "$2" ]]
}
