#!/usr/bin/env bash
# _cc_transcript_roots.sh — where Claude Code session transcripts live
# (your-org/nexus-code#1720). Source it; it defines one function and has
# no side effects at source time.
#
# THE DEFECT THIS CLOSES. Every orchestrator RESUME decision, the
# orchestrator liveness/freshness probes and spawn-worker's `--resume`
# looked for a transcript ONLY at `$HOME/.claude/projects/<slug>/<sid>.jsonl`.
# Claude Code writes to `$CLAUDE_CONFIG_DIR/projects` when CLAUDE_CONFIG_DIR
# is set, and inside agent-sandbox that is `~/.claude/sandbox-config`. The two
# are one directory only when the sandbox overlay symlinked
# `sandbox-config/projects` to `~/.claude/projects`, which it does only when
# the outside directory ALREADY EXISTED at the first sandbox launch. For an
# operator who never ran `claude` outside the sandbox, `sandbox-config/projects`
# is a REAL directory, so `_respawn_choose_resume_mode` answered `fresh` for
# every `--continue` boot and every respawn — at rc 0, with nothing on stderr.
#
# CONTRACT. `cc_transcript_roots [home]` prints one `<cc-home>/projects`
# directory per line, most specific first:
#
#   1. $NEXUS_CC_HOME/projects    (hermetic-test seam shared with
#                                  paste-followup.sh / _submit_evidence.sh /
#                                  window-session-id.sh / ng)
#   2. $CLAUDE_CONFIG_DIR/projects (where Claude Code actually writes when set)
#   3. <home>/.claude/projects     (<home> defaults to $HOME; the explicit
#                                  argument is the fake-home seam the liveness
#                                  probes' tests inject)
#
# Unset/empty entries are skipped, and entries that resolve to the SAME
# directory (`readlink -f` — the symlinked-overlay layout, where 2 and 3 are
# one tree) are printed once. A root is printed whether or not it exists:
# callers test the file they want under it, and "found under ANY root" is
# found.
#
# ADDITIVE, NOT EXCLUSIVE — deliberately unlike `se_cc_homes`, where
# NEXUS_CC_HOME is the ONLY root. Every caller of this function asks "does
# a transcript exist / is it fresh", and each one's failure direction is
# "no transcript": a FRESH spawn instead of a resume, or (in
# `_orchestrator_unresponsive`) a false-DEAD verdict. Consulting fewer roots
# can only make those answers falser, so no override narrows the set.
#
# Dedup is an efficiency detail, not a correctness one: every caller's
# predicate is idempotent over a repeated root.
cc_transcript_roots() {
    local home="${1:-${HOME:-}}"
    local -a cands=()
    [[ -n "${NEXUS_CC_HOME:-}" ]]     && cands+=( "$NEXUS_CC_HOME/projects" )
    [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && cands+=( "$CLAUDE_CONFIG_DIR/projects" )
    [[ -n "$home" ]]                  && cands+=( "$home/.claude/projects" )
    local c key seen=$'\n'
    for c in "${cands[@]}"; do
        # readlink -f fails (empty) when a non-final component is missing;
        # fall back to the literal path so a not-yet-created root still
        # prints and two distinct missing roots stay distinct.
        key=$(readlink -f -- "$c" 2>/dev/null) || key=""
        [[ -n "$key" ]] || key="$c"
        [[ "$seen" == *$'\n'"$key"$'\n'* ]] && continue
        seen+="$key"$'\n'
        printf '%s\n' "$c"
    done
    return 0
}
