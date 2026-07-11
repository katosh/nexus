# shellcheck shell=sh
# monitor/gh-shim.sh — the SHARED bot-default `gh` classification + token
# logic. Make the BOT the DEFAULT `gh` identity for nexus agents.
#
# SOURCE this (do not execute). It defines a `gh` shell FUNCTION carrying the
# WRITE/READ classifier, the bot-token auto-inject, the GH_IMPERSONATE escape
# hatch, and the fail-loud guards. It is the single source of truth for that
# policy, consumed by the PATH-FRONT WRAPPER (`monitor/ghwrap/gh`) — the
# delivery mechanism that puts a real `gh` executable first on PATH so a bare
# `gh` resolves to the bot default for the agent process AND every child it
# spawns (zsh, bash, `python subprocess`, Makefiles), not just zsh-direct
# calls (your-org/nexus-code PR #349, operator request: comment 4795415597).
#
# REAL-GH HAND-OFF. Every place this shim hands off to the actual gh binary
# goes through `_ghs_realgh` (defined just below), NOT a literal `command gh`.
# That indirection lets the PATH-front wrapper inject the RESOLVED ABSOLUTE
# path of the real gh — sidestepping a recursive PATH lookup (the wrapper is
# itself first on PATH). Sourced standalone (the unit-test harness, or a
# degraded fallback shell), the default `_ghs_realgh` resolves `gh` on PATH via
# `command` — behaviourally identical to the pre-wrapper code. A caller that
# pre-defines `_ghs_realgh` BEFORE sourcing wins (the wrapper does exactly that).
#
# Why a real executable rather than the earlier ZDOTDIR shell *function*: a
# function shadows `gh` only inside the zsh shells that source it — it does NOT
# propagate to bash subshells, `python subprocess`, or Makefiles. The sandbox
# does reshuffle PATH unpredictably (the chaperon prepends /app/bin in
# subshells, ~/.zshenv re-prepends linuxbrew on every invocation, and there are
# multiple `gh` binaries on disk) — so the wrapper dir is FORCE-prepended to the
# FRONT of PATH AFTER that late modification, per-command, in
# monitor/shellenv/.zshenv (and process-wide in monitor/locals-env.sh). That
# re-assertion is what wins the race the operator identified.
#
# WHY (your-org/nexus-code, repro: PR #345 comment 4790310194). The ambient
# `gh` in the sandbox is authed as the OPERATOR (operator). So the path of
# least resistance — a bare `gh pr comment …` — posts as the operator, not
# the bot. GitHub mutes notifications for actions taken by the recipient's
# own account, so an operator-authored "bot" comment silently fails to wake
# the operator AND pollutes the audit trail. The ack/relay path ("On it —
# …") is the high-frequency slip: agents use `ng`/the bot for the big final
# comment, then slip on the quick reply. Flipping the DEFAULT (bot for
# writes, loud opt-in to impersonate) removes the footgun at its root.
#
# HOW IT IS REACHED. The nexus launchers (worker `monitor/spawn-worker.sh`,
# orchestrator `monitor/watcher/_respawn.sh`, watcher `monitor/watcher/
# launcher.sh`) source `monitor/locals-env.sh`, which in full mode (a) prepends
# the wrapper dir `monitor/ghwrap` to PATH for the agent process and (b) exports
# `ZDOTDIR=$NEXUS_ROOT/monitor/shellenv`. Every `zsh -c` an agent runs — the
# Claude Code Bash tool uses zsh — sources `$ZDOTDIR/.zshenv`, which (after
# re-sourcing the operator's real ~/.zshenv) FORCE-prepends the wrapper dir to
# the FRONT of PATH again, so it wins even after ~/.zshenv re-prepends
# linuxbrew. The wrapper executable then sources THIS file for the policy.
#
# WATCHER SAFETY. The watcher runs bash and DOES get the wrapper on PATH (it
# sources locals-env), but it spawns with `WATCHER_WINDOW=headless` and its
# `gh` calls preset `GH_TOKEN` inline — so branches (0) and (1) below short-
# circuit to the real gh untouched (snapshot_mentions' intentional user-PAT
# graphql search; the inline-GH_TOKEN snapshot calls). The operator's own
# interactive shells use locals-env's PATH-ONLY mode (which returns before the
# wrapper prepend AND the ZDOTDIR export), so they never get the wrapper.
#
# CLASSIFICATION (see the verb table in skills/nexus.bot/SKILL.md):
#   WRITE  → auto-inject the bot token (minted via monitor/mint-token.sh,
#            the SAME source `ng` uses — no token logic is reimplemented):
#            pr create|edit|merge|comment|close|reopen|ready|review;
#            issue create|edit|comment|close|reopen|lock|unlock|delete|
#            transfer|pin|unpin|develop; release create|edit|delete|upload;
#            repo create|edit|delete|archive|unarchive|rename|fork|sync;
#            label create|edit|delete|clone; secret set|delete;
#            variable set|delete; gist create|edit|delete|rename;
#            `api` with --method/-X in {POST,PATCH,PUT,DELETE}, `api graphql`
#            (default graphql to the bot — mutations are hard to tell from
#            queries; the bot is the safe call), and `api <path>` with a
#            request body (-f/-F/--field/--raw-field, or --input <file>) and
#            no explicit GET (gh defaults those to POST). Ambiguous → WRITE.
#   READ + `gh auth …` → PASS THROUGH untouched. Reads don't notify;
#            `gh auth token` is the user-PAT path `ng fetch-asset` depends on.
#   GH_TOKEN already set → PASS THROUGH unchanged. The watcher and correct
#            callers set it explicitly; never double-inject or override.
#
# ESCAPE HATCH — operator identity, on purpose:
#   GH_IMPERSONATE=1 gh …            (or a `--dangerously-impersonate`
#   GH_IMPERSONATE_REASON='…' gh …    pseudo-flag the shim strips)
#   Uses the operator identity, REQUIRES a reason (refuses without one), and
#   appends an audit line to monitor/.state/impersonate.log. For the one
#   legitimate case: an external repo with NO bot install where the operator
#   explicitly authorised posting as themselves.
#
# `git commit` / `git push` are UNAFFECTED — they are git, not `gh`, and keep
# the operator identity (correct per the CLAUDE.md identity rule).
#
# Pure function definition: NO side effects at source time, fast, never
# fails the sourcing shell. POSIX-sh body so it is identical under zsh
# (agents) and bash (tests).

# Real-`gh` invoker — the SINGLE point where this shim hands off to the actual
# gh binary. Indirected so monitor/ghwrap/gh can pre-define it to call the
# resolved ABSOLUTE path (no recursive PATH lookup). Default (unit tests, or a
# degraded standalone source) finds `gh` on PATH via `command` — identical to
# the original inline `command gh`. A pre-existing definition wins (guard).
if ! command -v _ghs_realgh >/dev/null 2>&1; then
    _ghs_realgh() { command gh "$@"; }
fi

# Real gh, run with the OPERATOR's credentials deliberately restored.
#
# locals-env.sh scopes GH_CONFIG_DIR to a credential-free dir so that a gh
# reached WITHOUT this shim cannot authenticate at all (fail-closed). The paths
# that legitimately need the operator's own identity — `gh auth …` (whose whole
# job is to hand out the user PAT, e.g. `ng fetch-asset`), reads, and the
# audited GH_IMPERSONATE opt-in — opt back in HERE, explicitly and visibly.
#
# Where the operator's real gh credentials live. locals-env.sh records this
# only when GH_CONFIG_DIR or XDG_CONFIG_HOME was explicitly set (it may not name
# a home path — it is home-independent by contract). When it did NOT record one
# but DID scope GH_CONFIG_DIR, fall back to gh's own default here. This is the
# right home for that fallback: it is exactly the location gh consults.
#
# Prints nothing when locals-env.sh never ran (standalone source, a fork, a unit
# test) — the caller then degrades to a plain call, behaviour identical to
# before the scoping existed.
_ghs_opdir() {
    if [ -n "${NEXUS_OPERATOR_GH_CONFIG_DIR:-}" ]; then
        printf '%s' "$NEXUS_OPERATOR_GH_CONFIG_DIR"
    elif [ -n "${NEXUS_GH_CONFIG_SCOPED:-}" ]; then
        printf '%s' "${XDG_CONFIG_HOME:-${HOME:-}/.config}/gh"
    fi
}

_ghs_opcfg() {
    _ghs_dir=$(_ghs_opdir)
    if [ -n "$_ghs_dir" ]; then
        GH_CONFIG_DIR="$_ghs_dir" _ghs_realgh "$@"
    else
        _ghs_realgh "$@"
    fi
}

gh() {
    # (0) Watcher safety, defence-in-depth. The watcher runs bash and DOES
    #     pick up the PATH-front wrapper, but it spawns WATCHER_WINDOW=headless,
    #     so this branch passes its deterministic, self-tokened calls through
    #     to the real gh untouched. (Also covers a ZDOTDIR leak into a zsh
    #     subshell spawned in watcher context, e.g. an orchestrator restart.)
    #     Its own GH_TOKEN still wins over any config dir; restoring the
    #     operator config only keeps its unauthenticated reads working.
    if [ -n "${WATCHER_WINDOW:-}" ]; then
        _ghs_opcfg "$@"; return $?
    fi

    # (1) An explicit GH_TOKEN means the caller already chose the identity
    #     (the watcher's inline-token snapshots, `ng`, a deliberate
    #     GH_TOKEN=$(mint-token.sh) gh …). Never double-inject or override.
    if [ -n "${GH_TOKEN:-}" ]; then
        _ghs_realgh "$@"; return $?
    fi

    _ghs_root="${NEXUS_ROOT:-}"

    # (2) Impersonation escape hatch. GH_IMPERSONATE truthy, or a
    #     `--dangerously-impersonate` pseudo-flag, selects the operator
    #     identity. Requires a reason; audits; strips the pseudo-flag.
    _ghs_imp=0
    case "${GH_IMPERSONATE:-}" in
        1|true|TRUE|yes|YES|on|ON) _ghs_imp=1 ;;
    esac
    for _ghs_a in "$@"; do
        if [ "x$_ghs_a" = "x--dangerously-impersonate" ]; then _ghs_imp=1; break; fi
    done
    if [ "$_ghs_imp" = "1" ]; then
        if [ -z "${GH_IMPERSONATE_REASON:-}" ]; then
            printf 'gh-shim: GH_IMPERSONATE set but GH_IMPERSONATE_REASON is empty.\n' >&2
            printf 'gh-shim: refusing to post as the OPERATOR without a stated reason.\n' >&2
            printf 'gh-shim: retry as  GH_IMPERSONATE=1 GH_IMPERSONATE_REASON="why" gh …\n' >&2
            return 3
        fi
        # Rebuild the arg list without the pseudo-flag (POSIX rotate: pop the
        # front, push it back unless it is the flag).
        _ghs_n=$#
        while [ "$_ghs_n" -gt 0 ]; do
            _ghs_cur=$1; shift
            if [ "x$_ghs_cur" != "x--dangerously-impersonate" ]; then
                set -- "$@" "$_ghs_cur"
            fi
            _ghs_n=$((_ghs_n - 1))
        done
        if [ -n "$_ghs_root" ]; then
            _ghs_log="$_ghs_root/monitor/.state/impersonate.log"
            mkdir -p "$_ghs_root/monitor/.state" 2>/dev/null || true
            # Explicit mode at creation (your-org/nexus-code#484). This is an
            # AUDIT log — a group-writable impersonation trail is one anybody
            # in the unix group can rewrite, which is precisely what an audit
            # trail must not be. `_log-mode.sh` is POSIX sh for this caller.
            # Sourcing is guarded: a missing helper must never break `gh`.
            if ! command -v _ensure_service_log >/dev/null 2>&1; then
                # shellcheck source=_log-mode.sh
                . "$_ghs_root/monitor/_log-mode.sh" 2>/dev/null || true
            fi
            command -v _ensure_service_log >/dev/null 2>&1 \
                && _ensure_service_log "$_ghs_log" || true
            printf '%s\tpid=%s\twindow=%s\treason=%s\targv=gh %s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown-ts)" \
                "$$" "${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-unknown}}" \
                "$GH_IMPERSONATE_REASON" "$*" >> "$_ghs_log" 2>/dev/null || true
        fi
        printf 'gh-shim: impersonating the operator (reason: %s)\n' "$GH_IMPERSONATE_REASON" >&2
        _ghs_opcfg "$@"; return $?
    fi

    # (3) Classify the verb. Find the command GROUP (first token matching a
    #     known group, so a leading `--repo X`/`-R X` is skipped) and the
    #     SUBCOMMAND (next non-flag token after it).
    _ghs_grp=""; _ghs_sub=""; _ghs_seen=0
    for _ghs_a in "$@"; do
        if [ "$_ghs_seen" = 0 ]; then
            case " pr issue release repo label gist secret variable api workflow run cache codespace gpg-key ssh-key " in
                *" $_ghs_a "*) _ghs_grp="$_ghs_a"; _ghs_seen=1 ;;
            esac
        else
            case "$_ghs_a" in
                -*) continue ;;
            esac
            _ghs_sub="$_ghs_a"; break
        fi
    done

    _ghs_write=0
    case "$_ghs_grp" in
        api)
            # `gh api` defaults to GET, POSTs when a request body is supplied
            # (-f/-F/--field/--raw-field, OR --input <file>), and takes
            # --method/-X for everything else. graphql → treat as a mutation
            # by default (bot is the safe call).
            _ghs_method=""; _ghs_hasfield=0; _ghs_expect=0
            for _ghs_a in "$@"; do
                if [ "$_ghs_expect" = 1 ]; then _ghs_method="$_ghs_a"; _ghs_expect=0; continue; fi
                case "$_ghs_a" in
                    graphql) _ghs_write=1 ;;
                    -X|--method) _ghs_expect=1 ;;
                    -X*) _ghs_method="${_ghs_a#-X}" ;;
                    --method=*) _ghs_method="${_ghs_a#--method=}" ;;
                    -f|--raw-field|-F|--field|--input|--input=*) _ghs_hasfield=1 ;;
                esac
            done
            case "$_ghs_method" in
                POST|PATCH|PUT|DELETE|post|patch|put|delete) _ghs_write=1 ;;
            esac
            if [ "$_ghs_hasfield" = 1 ]; then
                case "$_ghs_method" in
                    GET|get|HEAD|head) : ;;
                    *) _ghs_write=1 ;;
                esac
            fi
            ;;
        pr)
            case "$_ghs_sub" in
                create|edit|merge|comment|close|reopen|ready|review) _ghs_write=1 ;;
            esac
            ;;
        issue)
            case "$_ghs_sub" in
                create|edit|comment|close|reopen|lock|unlock|delete|transfer|pin|unpin|develop) _ghs_write=1 ;;
            esac
            ;;
        release)
            case "$_ghs_sub" in
                create|edit|delete|upload) _ghs_write=1 ;;
            esac
            ;;
        repo)
            case "$_ghs_sub" in
                create|edit|delete|archive|unarchive|rename|fork|sync|set-default) _ghs_write=1 ;;
            esac
            ;;
        label)
            case "$_ghs_sub" in
                create|edit|delete|clone) _ghs_write=1 ;;
            esac
            ;;
        gist)
            case "$_ghs_sub" in
                create|edit|delete|rename) _ghs_write=1 ;;
            esac
            ;;
        secret|variable)
            case "$_ghs_sub" in
                set|delete|remove) _ghs_write=1 ;;
            esac
            ;;
        workflow)
            case "$_ghs_sub" in
                run|enable|disable) _ghs_write=1 ;;
            esac
            ;;
        run)
            case "$_ghs_sub" in
                cancel|rerun|delete) _ghs_write=1 ;;
            esac
            ;;
        cache)
            case "$_ghs_sub" in
                delete) _ghs_write=1 ;;
            esac
            ;;
        gpg-key|ssh-key)
            case "$_ghs_sub" in
                add|delete) _ghs_write=1 ;;
            esac
            ;;
    esac

    # (4) Reads, `gh auth …`, and everything unrecognised pass through — with
    #     the operator's config dir restored, since locals-env.sh scoped the
    #     ambient one away. Writes never reach here.
    if [ "$_ghs_write" = 0 ]; then
        _ghs_opcfg "$@"; return $?
    fi

    # (5) WRITE → inject the bot token. Single-source via mint-token.sh
    #     (MINT_TOKEN_BIN override mirrors the watcher's convention and lets
    #     tests inject a stub). Fail LOUD on an empty/failed mint rather than
    #     letting GH_TOKEN="" fall through to the operator's ambient auth —
    #     the CLAUDE.md security-boundary rule.
    _ghs_mint="${MINT_TOKEN_BIN:-}"
    if [ -z "$_ghs_mint" ]; then
        if [ -n "$_ghs_root" ]; then
            _ghs_mint="$_ghs_root/monitor/mint-token.sh"
        else
            printf 'gh-shim: NEXUS_ROOT unset and MINT_TOKEN_BIN unset — cannot mint a bot token.\n' >&2
            printf 'gh-shim: refusing WRITE `gh %s` to avoid a silent operator-identity fallthrough.\n' "$*" >&2
            return 1
        fi
    fi
    if [ ! -x "$_ghs_mint" ]; then
        printf 'gh-shim: mint-token.sh not executable at %s — refusing WRITE `gh %s`.\n' "$_ghs_mint" "$*" >&2
        return 1
    fi
    _ghs_tok=$("$_ghs_mint" 2>/dev/null) || {
        printf 'gh-shim: mint-token.sh failed — refusing WRITE `gh %s` (operator-identity fallthrough avoided).\n' "$*" >&2
        return 1
    }
    if [ -z "$_ghs_tok" ]; then
        printf 'gh-shim: mint-token.sh returned empty — refusing WRITE `gh %s`.\n' "$*" >&2
        return 1
    fi
    GH_TOKEN="$_ghs_tok" _ghs_realgh "$@"
}
