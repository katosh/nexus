#!/usr/bin/env bash
# monitor/_spawn-codex.sh — the Codex half of `spawn-worker.sh --harness codex`
# (your-org/nexus-code#1640, layer 2). Sourced by monitor/spawn-worker.sh only
# when the harness is codex; never executed.
#
# Everything spawn-worker.sh does that is HARNESS-INDEPENDENT stays there and
# is reused unchanged for a Codex worker: the argument contract, root/state
# resolution, the write probe, the skeptic self-spawn guard, the floor and
# prompt composition, the launcher PRELUDE (NEXUS_* exports, locals-env,
# TMPDIR, the nproc ceiling, the fail-closed shim guard, `cd`), the tmux
# window, the lifecycle anchors and the provenance record. This file holds
# only what differs, each item MEASURED on codex-cli 0.156.1:
#
#   * the binary and the credential the TUI needs ($CODEX_HOME/auth.json —
#     the TUI reads neither OPENAI_API_KEY nor CODEX_API_KEY);
#   * folder trust, which must be PERSISTED (codex-trust-workdir.sh);
#   * the launch argv: sandbox/approvals, the update check, instruction
#     files, the hooks that feed the nexus heartbeat, the model.
#
# Exit codes it can cause (spawn-worker.sh documents them in its header):
#   24  no codex binary, or a combination the Codex harness does not support
#   25  no credential the Codex TUI can use

# sw_codex_die <rc> <msg…>
sw_codex_die() { local rc="$1"; shift; printf 'spawn-worker: --harness codex: %s\n' "$*" >&2; exit "$rc"; }

# NEXUS_CODEX_EXTRA_CONFIG_FILE: one `key=value` per line (blank and `#`
# lines ignored), each passed as `-c <line>`. The hermetic suites point the
# worker at monitor/codex-harness/mock-responses.py through it; an operator
# can use it for per-nexus Codex settings. Read once, here.
sw_codex_extra_configs() {
    SW_CODEX_EXTRA=()
    local f="${NEXUS_CODEX_EXTRA_CONFIG_FILE:-}" ln
    [[ -n "$f" ]] || return 0
    [[ -r "$f" ]] || sw_codex_die 24 "NEXUS_CODEX_EXTRA_CONFIG_FILE=$f is not readable"
    while IFS= read -r ln || [[ -n "$ln" ]]; do
        [[ -z "${ln//[[:space:]]/}" || "$ln" =~ ^[[:space:]]*# ]] && continue
        SW_CODEX_EXTRA+=("$ln")
    done < "$f"
}

# sw_codex_preflight — sets SW_CODEX_BIN SW_CODEX_HOME SW_CODEX_MODEL.
sw_codex_preflight() {
    # shellcheck source=monitor/_codex.sh
    . "$NEXUS_ROOT/monitor/_codex.sh" || sw_codex_die 24 "cannot source monitor/_codex.sh"
    SW_CODEX_BIN=$(codex_bin) || sw_codex_die 24 "no codex binary (run monitor/install-codex-local.sh, or set CODEX_BIN)"
    SW_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
    SW_CODEX_MODEL="${MODEL:-$(codex_model_default)}"
    sw_codex_extra_configs
    # The TUI authenticates ONLY from $CODEX_HOME/auth.json (measured: with
    # OPENAI_API_KEY and CODEX_API_KEY set it still shows the login chooser,
    # which would hold the worker forever). A custom model_provider in the
    # extra config needs no OpenAI login at all (the mock suites).
    local custom=0 c
    for c in "${SW_CODEX_EXTRA[@]}"; do
        [[ "$c" == model_provider=* ]] && custom=1
    done
    if (( ! custom )) && [[ ! -s "$SW_CODEX_HOME/auth.json" ]]; then
        sw_codex_die 25 "no Codex login in $SW_CODEX_HOME/auth.json, and the Codex TUI reads no API key from the environment (measured). One-time OPERATOR action, inside the sandbox: printenv OPENAI_API_KEY | $SW_CODEX_BIN login --with-api-key   (or \`$SW_CODEX_BIN login\` for a ChatGPT plan). The key is read on stdin, never argv."
    fi
}

# sw_codex_seed_trust <workdir>
sw_codex_seed_trust() {
    "$NEXUS_ROOT/monitor/codex-trust-workdir.sh" "$1" --codex-home "$SW_CODEX_HOME" \
        || sw_codex_die 24 "could not persist Codex folder trust for $1 in $SW_CODEX_HOME/config.toml (an untrusted folder raises a blocking dialog)"
}

# sw_codex_launch_args — prints the codex argv (options only, shell-quoted,
# one line) that both the fresh and the resume launcher append their
# positional arguments to.
sw_codex_launch_args() {
    local hook="$NEXUS_ROOT/monitor/codex-hook.sh" ev args=()
    # -s danger-full-access: codex's bwrap sandbox cannot start inside this
    #    nexus's kernel sandbox (`bwrap: Failed to make / slave`), so every
    #    command fails under read-only/workspace-write. The kernel sandbox
    #    still binds. -a never: no approval dialogs in an unattended pane.
    args+=(-s danger-full-access -a never -m "$SW_CODEX_MODEL")
    # The update prompt is a blocking modal on first start (measured).
    args+=(-c check_for_update_on_startup=false)
    # CLAUDE.md files inside the workdir's repository reach Codex as if they
    # were AGENTS.md — the parity Claude gets — and the budget holds the
    # nexus CLAUDE.md whole (90 KB; the default 32 KiB truncated it, measured).
    args+=(-c 'project_doc_fallback_filenames=["CLAUDE.md"]' -c project_doc_max_bytes=262144)
    # Hooks → monitor/codex-hook.sh → worker-heartbeat.sh. Session-flag hooks
    # need Codex's hook-trust hash, which is not reproducible offline, so the
    # trust prompt is bypassed for them: parity with a Claude worker, whose
    # workspace is trusted and whose project hooks run under
    # --dangerously-skip-permissions. BELIEVED parity, not measured for the
    # Claude side here; the residual (a foreign repo's .codex/hooks.json runs
    # unreviewed) is stated in skills/nexus.codex/SKILL.md.
    args+=(--dangerously-bypass-hook-trust)
    # PreToolUse too (skeptic F4: Codex 0.156.1 HAS it): a tool's START marks
    # the turn busy, where PostToolUse only marks its end. The Claude
    # PreToolUse GUARDS (footgun, gh-write) are NOT wired: their matchers key
    # on Claude tool names (Bash/Write/Edit) and their payload contract for
    # Codex's tools (exec_command, apply_patch) is unmeasured — a follow-up.
    for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop; do
        args+=(-c "hooks.$ev=[{hooks=[{type=\"command\",command=\"$hook $ev\"}]}]")
    done
    local c
    for c in "${SW_CODEX_EXTRA[@]}"; do args+=(-c "$c"); done
    local out="" a
    for a in "${args[@]}"; do out+=" $(printf '%q' "$a")"; done
    printf '%s' "${out# }"
}

# sw_codex_addendum <floor-file> — the `## Codex worker addendum` section.
sw_codex_addendum() {
    awk '/^## Codex worker addendum[[:space:]]*$/{f=1;next} /^## /{f=0} f' "$1"
}

# sw_codex_rollout <session-id> — the rollout file codex resume needs, or rc 1.
sw_codex_rollout() {
    local sid="$1" f
    [[ -d "$SW_CODEX_HOME/sessions" ]] || return 1
    f=$(find "$SW_CODEX_HOME/sessions" -maxdepth 4 -type f -name "rollout-*-$sid.jsonl" -print 2>/dev/null | sed -n 1p)
    [[ -n "$f" ]] || return 1
    printf '%s\n' "$f"
}
