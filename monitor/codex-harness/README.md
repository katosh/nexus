# codex-harness — the real `codex` binary against a mock Responses API

The Codex counterpart of `monitor/cc-harness/` (<your-org>/nexus-code#1640).

`mock-responses.py` is an auth-free, stdlib-only (python 3.6-safe) mock of
the OpenAI Responses API. It lets the REAL Codex CLI (`codex exec` and the
TUI) run turns, including real tool calls, with no OpenAI credential and no
network egress. It binds 127.0.0.1 only, writes its port to
`$MOCK_DIR/port`, and logs every request to `$MOCK_DIR/requests.jsonl`.

Point codex at it without touching any config file:

    -c model_provider=nexusmock
    -c 'model_providers.nexusmock={name="nexusmock",base_url="http://127.0.0.1:PORT/v1",wire_api="responses"}'

Script each turn with `$MOCK_DIR/control.json` (schema in the file header):
`text`, `shell` (one function call to whichever shell tool the request
offers), `hang`, `error`. The step index is derived from the REQUEST, as the
tool round-trips since the last user message, so it is stateless across
processes and restarts every turn.

Measured on codex-cli 0.156.1:
- a custom provider without `env_key` sends no `Authorization` header;
- the gpt-6 catalogue entries expose shell only through a JavaScript
  code-mode tool; use `-m gpt-5.5` for `shell` scenarios (plain
  `exec_command`).

Users: `monitor/watcher/test-codex-run-real.sh`.
