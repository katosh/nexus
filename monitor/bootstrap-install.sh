#!/usr/bin/env bash
# Nexus install bootstrap — interactive, Claude-Code-driven setup.
#
# Invoked by a first-time operator as the foreground command of a
# fresh inner-tmux session created by agent-sandbox:
#
#   cd /path/to/nexus-code
#   agent-sandbox tmux new-session ./monitor/bootstrap-install.sh
#
# What this does, in order:
#
#   1. Self-checks: verify we're running inside tmux AND agent-sandbox,
#      and that the cwd looks like a nexus-code clone. Same sandbox/tmux
#      contract the watcher enforces — Claude Code will run with
#      `--dangerously-skip-permissions`, so an unconfined run is
#      explicitly refused.
#
#   2. Pre-flight notes: if config/nexus.yml already exists, warn the
#      operator (probably an existing install) and ask whether to
#      proceed. The bootstrap is designed for fresh installs; an
#      existing config means the operator likely wants `./watcher`,
#      not this script.
#
#   3. Ensure a Claude Code binary + resolve $CLAUDE_BIN: when no
#      operator-set $CLAUDE_BIN, no project-local
#      node_modules/.bin/claude, and no system `claude` on PATH
#      exists, run monitor/install-claude-local.sh to create the
#      project-local install. This is the fresh-operator path: a
#      host with no claude at all must be able to bootstrap, and
#      the resolver in _claude-bin.sh fails loud when nothing is
#      found — so the install has to happen here, before the
#      resolver, not as an agent step after it.
#
#   4. Compose the install-bootstrap prompt: read
#      `monitor/install-prompt.md` (the canonical bootstrap brief),
#      prepend a small per-launch context block (nexus root, the
#      operator's $USER, whether config/nexus.yml exists, the
#      resolved claude binary), and write the combined text to a
#      tmpfile.
#
#   5. Exec claude --dangerously-skip-permissions "$PROMPT". Claude
#      Code then walks the operator through:
#         - what nexus is, and what we'll do
#         - asset+issue repo creation (`gh repo create`)
#         - GitHub App creation in the browser
#         - webhook + smee.io setup
#         - config/nexus.yml generation from operator input
#         - smoke tests (`ng issue`, `ng preflight`, `ng upload`)
#         - overview-issue seed
#         - first `./watcher` launch
#
#   6. Cleanup: on exit, remove the tmpfile.
#
# This script is additive — the manual install path under
# `docs/getting-started/install.md` "Manual install (advanced)"
# remains supported for operators who prefer to do it themselves.
#
# Flags:
#   --force     Skip the existing-config refusal and proceed anyway.
#   -h / --help Print this header.

set -uo pipefail

# Hold the pane open on a failure exit. This script runs as the
# foreground command of `agent-sandbox tmux new-session
# ./monitor/bootstrap-install.sh`, so when it exits the tmux session
# ends and the pane closes — taking the error scrollback with it
# before the operator can read or copy it. On a non-zero exit, and
# only when attached to an interactive terminal, pause on a final
# Enter so the error above stays visible. The TTY guard ([ -t 0 ] /
# [ -t 1 ]) keeps non-interactive runs (CI, piped) from ever hanging.
_bootstrap_prompt_file=""
_hold_open_on_exit() {
    local rc=$?
    [[ -n "$_bootstrap_prompt_file" ]] && rm -f "$_bootstrap_prompt_file"
    if (( rc != 0 )) && [[ -t 0 && -t 1 ]]; then
        printf '\n[bootstrap-install] exited with status %d — review the error above.\n' "$rc" >&2
        printf '[bootstrap-install] press Enter to close this window... ' >&2
        read -r _ || true
    fi
    return "$rc"
}
trap _hold_open_on_exit EXIT

_script_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
_nexus_root=$(cd "$_script_dir/.." && pwd)
_prompt_template="$_script_dir/install-prompt.md"

# Public-template disable switch — the installer execs a
# `--dangerously-skip-permissions` Claude session, so gate it too.
# Refuse unless NEXUS_PUBLIC_ENABLED=1. See monitor/_public-guard.sh.
# shellcheck source=_public-guard.sh
source "$_script_dir/_public-guard.sh"
nexus_public_guard

FORCE=0
while (( $# > 0 )); do
    case "$1" in
        --force)   FORCE=1; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "bootstrap-install: unknown flag: $1" >&2; exit 1 ;;
    esac
done

# --- self-checks ----------------------------------------------------------

if [[ -z "${TMUX:-}" ]]; then
    cat >&2 <<'ERR'
bootstrap-install: not running inside a tmux session.

Fix:
  cd /path/to/nexus-code
  agent-sandbox tmux new-session ./monitor/bootstrap-install.sh

The bootstrap launches Claude Code with --dangerously-skip-permissions,
which is only defensible inside the agent-sandbox tmux session. Run
this script as the foreground command of a fresh inner-tmux session.
ERR
    exit 2
fi

if [[ "${SANDBOX_ACTIVE:-}" != "1" || -z "${SANDBOX_PROJECT_DIR:-}" ]]; then
    cat >&2 <<'ERR'
bootstrap-install: not running inside agent-sandbox.

Fix:
  cd /path/to/nexus-code
  agent-sandbox tmux new-session ./monitor/bootstrap-install.sh

agent-sandbox confines Claude Code's filesystem writes to the nexus
root and ~/.claude/. Without it, the bootstrap agent runs with
--dangerously-skip-permissions in an unconfined shell — refused.

If you don't have agent-sandbox installed yet:
  brew tap operator/tools && brew install agent-sandbox
ERR
    exit 2
fi

# Nexus-code clone shape check. Three load-bearing artefacts:
#   - monitor/ng              the bot CLI the prompt will invoke
#   - config/nexus.example.yml  the template we'll copy from
#   - watcher                 the symlink → monitor/watcher/entry.sh
for marker in monitor/ng config/nexus.example.yml watcher; do
    if [[ ! -e "$_nexus_root/$marker" ]]; then
        cat >&2 <<ERR
bootstrap-install: '$_nexus_root' does not look like a nexus-code clone.

Missing: $marker

Fix:
  cd /path/to/parent
  git clone https://github.com/your-org/nexus-code.git
  cd nexus-code
  agent-sandbox tmux new-session ./monitor/bootstrap-install.sh
ERR
        exit 2
    fi
done

if [[ ! -f "$_prompt_template" ]]; then
    cat >&2 <<ERR
bootstrap-install: install prompt missing at $_prompt_template

Your nexus-code checkout may be incomplete or pre-dates the bootstrap
flow. Try a fresh clone of your-org/nexus-code, or run the manual
install path documented at docs/getting-started/install.md
("Manual install (advanced)" section).
ERR
    exit 2
fi

# --- pre-flight -----------------------------------------------------------

CONFIG_EXISTS=0
if [[ -f "$_nexus_root/config/nexus.yml" ]]; then
    CONFIG_EXISTS=1
    if (( FORCE == 0 )); then
        cat >&2 <<ERR
bootstrap-install: $_nexus_root/config/nexus.yml already exists.

This usually means nexus is already installed on this host. The
bootstrap is designed for fresh installs; running it against an
existing config risks overwriting your bot credentials.

If you want to re-run the watcher:
  agent-sandbox tmux new-session ./watcher

If you really want to re-bootstrap (e.g. moving to a new asset
repo), back up the existing config first, then:
  mv config/nexus.yml config/nexus.yml.bak
  agent-sandbox tmux new-session ./monitor/bootstrap-install.sh

To proceed without backing up (the bootstrap will see the existing
config and ask you what to do), pass --force:
  agent-sandbox tmux new-session ./monitor/bootstrap-install.sh --force
ERR
        exit 3
    fi
fi

# --- ensure a claude binary, resolve $CLAUDE_BIN --------------------------

# Chicken-and-egg guard: _claude-bin.sh fails loud (exit 1) when no
# binary exists, so on a host with no system claude a fresh clone
# could never bootstrap — the resolver would kill this script before
# the agent it exists to launch ever runs. The bootstrap therefore
# performs the project-local install itself when nothing usable is
# present.
#
# The install is skipped when any of the resolver's three lookups
# would already succeed:
#   - $CLAUDE_BIN set by the operator (explicit override),
#   - $_nexus_root/node_modules/.bin/claude present (already installed),
#   - `claude` on PATH (operator intentionally on a system install).
# install-claude-local.sh is itself idempotent, but honoring an
# existing system claude or operator override means we never force a
# local install on someone who deliberately runs without one.
FRESH_INSTALL=0
if [[ -z "${CLAUDE_BIN:-}" ]] \
    && [[ ! -x "$_nexus_root/node_modules/.bin/claude" ]] \
    && ! command -v claude >/dev/null 2>&1; then
    FRESH_INSTALL=1
    echo "bootstrap-install: no usable claude binary on this host — installing project-local Claude Code" >&2
    echo "bootstrap-install: npm output follows (a cold cache can take a few minutes)" >&2
    if ! "$_nexus_root/monitor/install-claude-local.sh"; then
        cat >&2 <<ERR

bootstrap-install: project-local Claude Code install failed — the
error above names the cause and the recovery command.

After fixing it, either run the install manually:
  $_nexus_root/monitor/install-claude-local.sh
or simply relaunch the bootstrap (it retries the install):
  agent-sandbox tmux new-session ./monitor/bootstrap-install.sh
ERR
        exit 1
    fi
fi

# Resolve $CLAUDE_BIN (env override → project-local install → PATH).
# The install block above guarantees at least one lookup succeeds,
# so the resolver's fail-loud exit cannot trigger here.
NEXUS_ROOT="$_nexus_root"
# shellcheck disable=SC1091
. "$_nexus_root/monitor/_claude-bin.sh"

# --- nexus toolchain on PATH for manual tmux windows (#307 items 3+4) ------
#
# Provision the stable locals/bin tool links (claude, ng, nexus, watcher) and
# install the PATH-only rc hook so a NEW operator who later opens a tmux
# window by hand and runs `claude` lands on the project-local install — not a
# system/$HOME one. Both are idempotent + best-effort: a failure here must
# never abort a fresh install (the rc hook degrades gracefully on a read-only
# $HOME, printing the manual block). The link step also runs inside
# install-claude-local.sh; repeating it is a cheap no-op.
SHELL_HOOK_DONE=0
if [[ -x "$_nexus_root/monitor/link-nexus-tools.sh" ]]; then
    NEXUS_ROOT="$_nexus_root" "$_nexus_root/monitor/link-nexus-tools.sh" \
        || echo "bootstrap-install: warning: could not provision locals/bin links" >&2
fi
if [[ -x "$_nexus_root/monitor/install-shell-hook.sh" ]]; then
    if NEXUS_ROOT="$_nexus_root" "$_nexus_root/monitor/install-shell-hook.sh"; then
        SHELL_HOOK_DONE=1
    fi
fi

# --- compose the prompt ---------------------------------------------------

# Probe the host for your-lab addon eligibility (HPC, hpc-skills
# already installed, labsh already installed). The signals feed the
# install-prompt's "Phase X — Lab-specific addons" decision logic; on
# non-your-lab hosts they all read 'no' and the phase becomes a no-op.
# shellcheck disable=SC1091
. "$_script_dir/_lab-context.sh"
_hpc_kv=$(nexus_detect_hpc)
_hpc_skills_kv=$(nexus_detect_hpc_skills_installed)
_labsh_kv=$(nexus_detect_labsh_installed)
_hpc_yesno=$([[ $_hpc_kv == "hpc=1" ]] && echo "yes" || echo "no")
_hpc_skills_yesno=$([[ $_hpc_skills_kv == "installed=1" ]] && echo "yes" || echo "no")
_labsh_yesno=$([[ $_labsh_kv == "installed=1" ]] && echo "yes" || echo "no")

prompt_file=$(mktemp --suffix=.md "${TMPDIR:-/tmp}/nexus-bootstrap-prompt-XXXXXX")
# Register the tmpfile with the hold-open EXIT trap installed at the top
# of the script (don't replace that trap — it also keeps the pane open
# on error). _hold_open_on_exit rm -f's this path on exit.
_bootstrap_prompt_file="$prompt_file"

{
    cat <<HEADER
# Nexus install bootstrap (this session)

You are launching as a one-shot install bootstrap agent. The
operator has just run \`./monitor/bootstrap-install.sh\` from a
fresh nexus-code clone. Per-launch context:

- Nexus root:               $_nexus_root
- Operator shell user:      ${USER:-unknown}
- Sandbox project dir:      ${SANDBOX_PROJECT_DIR:-}
- config/nexus.yml exists:  $([[ $CONFIG_EXISTS == 1 ]] && echo "yes (operator passed --force)" || echo "no — fresh install")
- Claude binary:            $CLAUDE_BIN$([[ $FRESH_INSTALL == 1 ]] && echo " (project-local, installed by this bootstrap — no install step needed from you)")
- Manual-window PATH hook:  $([[ $SHELL_HOOK_DONE == 1 ]] && echo "installed into the operator's ~/.bashrc + ~/.zshrc (PATH-only; \`claude\`/\`ng\` resolve by name in manually-opened tmux windows; opt out via monitor/install-shell-hook.sh --uninstall)" || echo "not installed (read-only \$HOME or no rc) — tell the operator to add it by hand: monitor/install-shell-hook.sh --print")
- HPC host (your-institution):       $_hpc_yesno
- hpc-skills installed:     $_hpc_skills_yesno
- labsh installed:             $_labsh_yesno

Read the bootstrap brief below in full before your first reply.
Greet the operator with a one-paragraph summary of what you'll
walk them through, then begin with **Phase 0**.

---

HEADER
    cat "$_prompt_template"
} > "$prompt_file"

# --- launch claude --------------------------------------------------------

# Rename this tmux window to `bootstrap` so it's distinguishable
# from a later `claude` (orchestrator) window if the operator
# subsequently runs ./watcher in the same session.
tmux rename-window bootstrap 2>/dev/null || true

prompt_text=$(<"$prompt_file")
rm -f "$prompt_file"
# Clear the tracking var (file is gone), but keep the hold-open EXIT
# trap installed: if the exec below fails, the trap still pauses so the
# operator can read the error rather than the pane vanishing.
_bootstrap_prompt_file=""

cd "$_nexus_root"

# $CLAUDE_BIN was resolved (and, if needed, installed) in the
# "ensure a claude binary" section above, before prompt composition.
exec "$CLAUDE_BIN" --dangerously-skip-permissions "$prompt_text"
