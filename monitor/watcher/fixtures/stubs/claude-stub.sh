#!/usr/bin/env bash
# Records argv + stdin to $CLAUDE_STUB_RECORD_FILE then exits.
# Used by bootstrap-install tests to capture what would have been
# passed to claude --dangerously-skip-permissions "$PROMPT" without
# actually running claude.
#
# Env:
#   CLAUDE_STUB_RECORD_FILE  required — output path
#   CLAUDE_STUB_EXIT         optional — exit code (default 0)
set -uo pipefail

record_file="${CLAUDE_STUB_RECORD_FILE:?CLAUDE_STUB_RECORD_FILE not set}"
{
    echo "argc=$#"
    i=0
    for arg in "$@"; do
        i=$(( i + 1 ))
        printf 'argv[%d]=%s\n' "$i" "$arg"
    done
    if [[ ! -t 0 ]]; then
        echo "--- stdin ---"
        cat || true
    fi
} > "$record_file"

exit "${CLAUDE_STUB_EXIT:-0}"
