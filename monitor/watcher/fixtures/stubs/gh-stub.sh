#!/usr/bin/env bash
# Records subcommand+args; emits fixture data per subcommand.
# Used by bootstrap-install / install-prompt walkthrough tests to
# replace real gh on PATH so no network is touched.
#
# Env:
#   GH_STUB_RECORD_FILE      required — append each invocation
#   GH_STUB_FIXTURE_DIR      required — per-subcommand .out fixtures
#                            (gh_repo.out, gh_auth.out, gh_api.out,
#                             gh_label.out, gh_issue.out, gh_pr.out)
#   GH_STUB_EXIT             optional — exit code (default 0)
set -uo pipefail

record_file="${GH_STUB_RECORD_FILE:?GH_STUB_RECORD_FILE not set}"
fixture_dir="${GH_STUB_FIXTURE_DIR:?GH_STUB_FIXTURE_DIR not set}"

printf 'argv: %s\n' "$*" >> "$record_file"

sub="${1:-}"
case "$sub" in
    repo)   cat "$fixture_dir/gh_repo.out"   2>/dev/null || true ;;
    auth)   cat "$fixture_dir/gh_auth.out"   2>/dev/null || true ;;
    api)    cat "$fixture_dir/gh_api.out"    2>/dev/null || true ;;
    label)  cat "$fixture_dir/gh_label.out"  2>/dev/null || true ;;
    issue)  cat "$fixture_dir/gh_issue.out"  2>/dev/null || true ;;
    pr)     cat "$fixture_dir/gh_pr.out"     2>/dev/null || true ;;
    --version) echo "gh version 2.50.0 (stub)" ;;
    "")     echo "gh-stub: missing subcommand" >&2; exit 64 ;;
    *)      echo "gh-stub: unrecognised subcommand: $sub" >&2; exit 64 ;;
esac

exit "${GH_STUB_EXIT:-0}"
