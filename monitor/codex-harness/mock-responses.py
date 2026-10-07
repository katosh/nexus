#!/usr/bin/env python3
"""Auth-free, injectable mock of the OpenAI Responses API, for the real `codex`.

Drives the *real* Codex CLI (`codex exec` and the interactive TUI) with NO
OpenAI credential and NO network egress, so the nexus can exercise codex's
real boot / hook / tool-loop / pane-rendering machinery against scripted
backend responses. The Codex counterpart of monitor/cc-harness/mock-backend.py
(your-org/nexus-code#1640). See monitor/codex-harness/README.md.

Codex is pointed here with a custom model provider, never by editing a config
file:

    -c model_provider=nexusmock
    -c 'model_providers.nexusmock={name="nexusmock",base_url="http://127.0.0.1:PORT/v1",wire_api="responses"}'

A custom provider does not use websockets unless it opts in, so every turn is
one `POST /v1/responses` answered with an SSE stream.

Design constraints:
  - stdlib only, python 3.6-safe (ThreadingMixIn, no ThreadingHTTPServer);
  - binds 127.0.0.1 only;
  - every request is appended to <MOCK_DIR>/requests.jsonl (path, the last
    input item's type/role, the tool names offered, and the full body when
    MOCK_LOG_BODY=1) so a failing scenario is debuggable from one file.

INJECTABLE CONTROL. $MOCK_CONTROL (default <MOCK_DIR>/control.json) is re-read
FRESH on every request. It is either one step object, or {"steps": [...]}: a
script for ONE user turn, indexed by the number of tool round-trips since the
last user message in the request (so it restarts every turn, and is stateless
across processes); the last step repeats. A step:

  {
    "mode":     "text" | "shell" | "hang" | "error",
    "text":     "<assistant text>",       # text mode (default MOCK_OK)
    "command":  "sleep 5; echo hi",       # shell mode: the command the model
                                          #   asks codex to run (one call)
    "delay_ms": 0,                        # pause before the first SSE byte
    "drip_ms":  0,                        # pause between text deltas: a
                                          #   visible busy window for panes
    "status":   429,                      # error mode: HTTP status
    "error_text": "..."                   # error mode: message body
  }

`shell` mode answers with a function call to whichever shell tool the request
OFFERS (`exec_command`, `shell_command` or `shell`; logged as offered_tools),
so the mock follows the binary rather than hard-coding one version's name.
After codex posts the tool output back, the next request advances the script.
`hang` holds the stream open (heartbeat comments) until the client goes away:
the deterministic "busy forever" a pane classifier needs.
"""
import json
import os
import socketserver
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

MOCK_DIR = os.environ.get("MOCK_DIR") or os.getcwd()
CONTROL = os.environ.get("MOCK_CONTROL") or os.path.join(MOCK_DIR, "control.json")
LOG = os.path.join(MOCK_DIR, "requests.jsonl")
_lock = threading.Lock()
_counter = {"n": 0}

SHELL_TOOLS = ("exec_command", "shell_command", "shell", "local_shell")


def _turn_position(body):
    """Tool round-trips since the last user-authored message: the step index.

    Derived from the REQUEST, not from a server-global counter, so the script
    restarts on every user turn and two codex processes sharing one mock never
    advance each other's script (a counter did exactly that while this file
    was being written: run 2 began at step 1)."""
    items = [i for i in (body.get("input") or []) if isinstance(i, dict)]
    last_user = -1
    for k, it in enumerate(items):
        if it.get("type") == "message" and it.get("role") == "user":
            last_user = k
    return sum(1 for it in items[last_user + 1:]
               if str(it.get("type", "")).endswith("_call_output"))


def _load_step(n):
    try:
        with open(CONTROL) as fh:
            ctl = json.load(fh)
    except Exception:
        return {"mode": "text", "text": os.environ.get("MOCK_TEXT", "MOCK_OK")}
    steps = ctl.get("steps") if isinstance(ctl, dict) else None
    if isinstance(steps, list) and steps:
        return steps[min(n, len(steps) - 1)]
    return ctl if isinstance(ctl, dict) else {"mode": "text"}


def _tool_names(body):
    names = []
    for t in body.get("tools") or []:
        if isinstance(t, dict):
            names.append(t.get("name") or t.get("type") or "?")
    return names


def _log(rec):
    with _lock:
        with open(LOG, "a") as fh:
            fh.write(json.dumps(rec) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet stderr; requests.jsonl is the log
        pass

    def _sse(self, event, data):
        payload = dict(data)
        payload["type"] = event
        chunk = "event: %s\ndata: %s\n\n" % (event, json.dumps(payload))
        self.wfile.write(chunk.encode())
        self.wfile.flush()

    def do_GET(self):
        # /v1/models and friends: an empty catalogue is a valid answer.
        body = json.dumps({"object": "list", "data": [], "models": []}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        _log({"ts": time.time(), "method": "GET", "path": self.path})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode() or "{}")
        except Exception:
            body = {}
        with _lock:
            n = _counter["n"]
            _counter["n"] += 1
        pos = _turn_position(body)
        step = _load_step(pos)
        items = body.get("input") or []
        last = items[-1] if items and isinstance(items[-1], dict) else {}
        rec = {
            "ts": time.time(), "n": n, "pos": pos, "method": "POST", "path": self.path,
            "mode": step.get("mode", "text"),
            "last_input_type": last.get("type"), "last_input_role": last.get("role"),
            "offered_tools": _tool_names(body), "model": body.get("model"),
            # The first 12 chars of Authorization ONLY — enough for a suite to
            # assert that the dummy key, not a real one, reached the mock
            # ("Bearer mock-" vs "Bearer sk-pr"), never enough to be a key.
            "auth_prefix": (self.headers.get("Authorization") or "")[:12],
        }
        if os.environ.get("MOCK_LOG_BODY") == "1":
            rec["body"] = body
        _log(rec)

        if not self.path.rstrip("/").endswith("/responses"):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        mode = step.get("mode", "text")
        if mode == "error":
            msg = json.dumps({"error": {"message": step.get("error_text", "mock error"),
                                        "type": "mock_error"}}).encode()
            self.send_response(int(step.get("status", 500)))
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        time.sleep(float(step.get("delay_ms", 0)) / 1000.0)
        rid = "resp_mock_%d_%s" % (n, uuid.uuid4().hex[:8])
        try:
            self._sse("response.created", {"response": {"id": rid}})
            if mode == "hang":
                while True:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    time.sleep(1.0)
            elif mode == "shell":
                offered = _tool_names(body)
                name = next((t for t in SHELL_TOOLS if t in offered), "shell")
                cmd = step.get("command", "true")
                if name == "exec_command":
                    args = {"cmd": cmd}
                elif name == "shell_command":
                    args = {"command": cmd}
                else:
                    args = {"command": ["bash", "-lc", cmd]}
                item = {"type": "function_call", "id": "fc_%s" % uuid.uuid4().hex[:8],
                        "call_id": "call_%s" % uuid.uuid4().hex[:8], "name": name,
                        "arguments": json.dumps(args), "status": "completed"}
                self._sse("response.output_item.added", {"output_index": 0, "item": item})
                self._sse("response.output_item.done", {"output_index": 0, "item": item})
            else:
                text = step.get("text", os.environ.get("MOCK_TEXT", "MOCK_OK"))
                mid = "msg_%s" % uuid.uuid4().hex[:8]
                drip = float(step.get("drip_ms", 0)) / 1000.0
                self._sse("response.output_item.added", {"output_index": 0, "item": {
                    "type": "message", "id": mid, "role": "assistant", "content": []}})
                words = text.split(" ")
                for i, w in enumerate(words):
                    delta = w if i == 0 else " " + w
                    self._sse("response.output_text.delta", {"item_id": mid, "output_index": 0,
                                                             "content_index": 0, "delta": delta})
                    if drip:
                        time.sleep(drip)
                self._sse("response.output_item.done", {"output_index": 0, "item": {
                    "type": "message", "id": mid, "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": text, "annotations": []}]}})
            self._sse("response.completed", {"response": {
                "id": rid, "usage": {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0},
                                     "output_tokens": 5, "output_tokens_details": {"reasoning_tokens": 0},
                                     "total_tokens": 15}}})
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    port = int(os.environ.get("MOCK_PORT", "0"))
    srv = Server(("127.0.0.1", port), Handler)
    port_file = os.environ.get("MOCK_PORT_FILE") or os.path.join(MOCK_DIR, "port")
    tmp = port_file + ".tmp"
    with open(tmp, "w") as fh:
        fh.write("%d\n" % srv.server_address[1])
    os.rename(tmp, port_file)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
