#!/usr/bin/env python3
"""Auth-free, injectable mock Anthropic Messages backend.

Drives the *real* `claude` binary with NO Anthropic credentials and NO
network egress, so the nexus test harness can exercise the real boot /
hook / tool-loop / pane-rendering machinery against canned or
pipe-injected backend responses. See monitor/cc-harness/README.md.

Design constraints:
  - stdlib only (works on the cluster's python3.6 — no ThreadingHTTPServer
    until 3.7, so we compose it from ThreadingMixIn).
  - binds 127.0.0.1 only; refuses to be reachable off-box.
  - every request is logged (method, path, headers, decoded shape) so a
    failing scenario is debuggable from one file.

Response is content-negotiated against what Claude Code actually sends:
  - body `"stream": true`  OR  Accept: text/event-stream  -> SSE stream
  - otherwise                                             -> plain JSON
(Headless `claude -p` streams with Accept: application/json; the
interactive TUI streams too. The JSON branch covers non-streaming SDK
callers and keeps the mock honest.)

INJECTABLE CONTROL — the operator asked for "a pipe we can inject text
into." Realized here as a per-request **control file** (deterministic
and CI-robust; a FIFO is a documented follow-up). Path comes from
$MOCK_CONTROL (default <MOCK_DIR>/control.json). It is re-read FRESH on
every /v1/messages request, so a scenario mutates it between turns to
script each response. Schema (all keys optional):

  {
    "mode":      "text" | "hang" | "tool_use" | "error",
    "text":      "<assistant text>",        # text/tool_use modes
    "delay_ms":  0,                          # pause before first SSE byte
    "drip_ms":   0,                          # pause between text chunks
                                             #   (splits text on spaces ->
                                             #    a visible busy window so
                                             #    pane-state sees the
                                             #    `↑ N tokens` spinner)
    "tool":      {"name": "Bash",            # tool_use mode: emit a
                  "input": {"command":"ls"}},#   tool_use block
    "status":    500,                        # error mode: HTTP status
    "error_type":"api_error",                # error mode: Anthropic error
                                             #   .type (overloaded_error /
                                             #    not_found_error /
                                             #    invalid_request_error / …)
                                             #   -> drives the StopFailure
                                             #    `error` token CC surfaces
    "error_text":"..."                       # error mode: message body
  }

When the control file is absent/malformed, falls back to a single-shot
text response of $MOCK_TEXT (default "MOCK_OK_HELLO").
"""
import json
import os
import sys
import time
import socketserver
from http.server import BaseHTTPRequestHandler, HTTPServer


class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    """3.6-safe stand-in for http.server.ThreadingHTTPServer (3.7+)."""
    daemon_threads = True
    allow_reuse_address = True


MOCK_DIR = os.environ.get("MOCK_DIR", os.getcwd())
LOG_PATH = os.environ.get("MOCK_LOG", os.path.join(MOCK_DIR, "requests.log"))
CONTROL_PATH = os.environ.get("MOCK_CONTROL", os.path.join(MOCK_DIR, "control.json"))
DEFAULT_TEXT = os.environ.get("MOCK_TEXT", "MOCK_OK_HELLO")


def log(msg):
    line = msg if msg.endswith("\n") else msg + "\n"
    sys.stderr.write(line)
    sys.stderr.flush()
    try:
        with open(LOG_PATH, "a") as fh:
            fh.write(line)
    except OSError:
        pass


def read_control():
    """Re-read the control file fresh on every request. Missing or
    malformed -> default single-shot text directive."""
    try:
        with open(CONTROL_PATH) as fh:
            ctl = json.load(fh)
        if isinstance(ctl, dict):
            return ctl
    except (OSError, ValueError):
        pass
    return {"mode": "text", "text": DEFAULT_TEXT}


def sse(event, data):
    return "event: {}\ndata: {}\n\n".format(event, json.dumps(data)).encode()


def usage_block(ctl, output_tokens):
    """Usage object for a Messages response. Optional control knobs
    `cache_read` / `cache_creation` (ints, default 0) inject
    `cache_read_input_tokens` / `cache_creation_input_tokens` so the mock
    can advertise a WARM prompt cache. Claude Code skips its background
    `prompt-suggestion` request when the cache looks cold, so this knob is
    what lets the harness exercise the (model-driven) autosuggest path
    against the mock. Cold cache (the keys absent) is the default and
    preserves prior behavior."""
    u = {"input_tokens": 10, "output_tokens": output_tokens}
    cr = int(ctl.get("cache_read", 0) or 0)
    cc = int(ctl.get("cache_creation", 0) or 0)
    if cr or cc:
        u["cache_read_input_tokens"] = cr
        u["cache_creation_input_tokens"] = cc
    return u


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # silence default access-log noise
        pass

    def _read_body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(n) if n else b""

    def _dump(self, body):
        log("=== {} {} ===".format(self.command, self.path))
        for k, v in self.headers.items():
            log("  H {}: {}".format(k, v))
        if body:
            try:
                obj = json.loads(body)
                # Keep the log readable: model + last user turn only.
                last = ""
                msgs = obj.get("messages", [])
                if msgs:
                    last = json.dumps(msgs[-1])[:400]
                log("  REQ model={} n_messages={} last={}".format(
                    obj.get("model"), len(msgs), last))
            except ValueError:
                log("  BODY(raw) {!r}".format(body[:400]))

    def _json(self, code, obj, headers=None):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        for k, v in (headers or {}).items():
            self.send_header(str(k), str(v))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self._dump(b"")
        self._json(200, {"ok": True})

    def do_POST(self):
        body = self._read_body()
        self._dump(body)
        if os.environ.get("MOCK_DUMP_BODIES"):
            try:
                with open(os.path.join(MOCK_DIR, "bodies.log"), "a") as fh:
                    fh.write("\n===BODY {} {} beta={}\n".format(
                        self.command, self.path,
                        self.headers.get("anthropic-beta", "")))
                    fh.write(body.decode("utf-8", "replace"))
                    fh.write("\n")
            except OSError:
                pass
        path = self.path.split("?", 1)[0].rstrip("/")
        if not path.endswith("/v1/messages"):
            return self._json(200, {"ok": True})

        try:
            req = json.loads(body) if body else {}
        except ValueError:
            req = {}
        ctl = read_control()
        mode = ctl.get("mode", "text")
        accept = self.headers.get("Accept", "")
        wants_stream = bool(req.get("stream")) or "text/event-stream" in accept
        log("  -> mode={} stream={} accept={!r}".format(mode, wants_stream, accept))

        # Structured-output request? Claude Code makes a background call with
        # `output_config.format = {type: json_schema, schema: {...}}` to
        # generate the SESSION TITLE — the short label shown in session lists /
        # the UI (system prompt: "Generate a concise, sentence-case title…
        # Return JSON with a single 'title' field"; schema
        # `{properties:{title:string}, required:[title]}`). This is a UI-hint
        # feature, NOT the input-box prompt suggestion (that is a separate
        # call we have not yet been able to elicit against a custom backend).
        # We must answer with schema-conforming JSON or CC discards it. Fires
        # only when the cache looks warm (see usage_block / cache_read), and is
        # handled independently of the turn `mode`. The generic schema-fill
        # below also covers any future structured-output call shape.
        oc = req.get("output_config") or {}
        fmt = oc.get("format") if isinstance(oc, dict) else None
        if isinstance(fmt, dict) and fmt.get("type") == "json_schema":
            return self._respond_structured(req, ctl, fmt.get("schema") or {},
                                             wants_stream)

        # Prompt-suggestion request? Claude Code's input-box autosuggest is a
        # SEPARATE call that reuses the conversation (same system prompt → warm
        # cache) and appends a final user message tagged `[SUGGESTION MODE: …]`.
        # It carries NO json_schema (output_config is just `{effort}`) and wants
        # a PLAIN-TEXT reply of ONLY the suggested prompt (2-12 words, no quotes,
        # no "Claude-voice"). CC renders that text as the grey ghost in the input
        # box; Tab accepts it. Fires on idle after turn 2+ (skipped turn 1). We
        # answer it from the `suggestion` control knob, independent of `mode`.
        if self._is_suggestion_request(req):
            text = ctl.get("suggestion", "run the tests")
            log("  -> prompt suggestion: {!r}".format(text))
            return self._respond_with_text(req, ctl, text, wants_stream)

        if mode == "error":
            # `error_type` lets a scenario spoof the exact Anthropic error
            # SHAPE, not just the HTTP status — Claude Code maps the
            # (status, error.type) pair to the structured `error` token it
            # surfaces in the StopFailure hook payload, which is what the
            # stall-detection classifier keys off. Observed mappings against
            # the real binary: 529/overloaded_error -> "server_error"
            # (transient -> paste); 404/not_found_error -> "model_not_found"
            # (config -> respawn); 400/invalid_request_error -> "unknown"
            # (msg-probed -> conversation -> respawn). Defaults to api_error
            # (the generic 5xx shape) to preserve prior behavior.
            # `headers` (optional map) lets a scenario attach response
            # headers to the error. Empirical note for over-limit
            # spoofing (claude 2.1.x, test-realmodel-overlimit.sh):
            # the SUBSCRIPTION usage-limit flow (anthropic-ratelimit-
            # unified-status: rejected → hard stop + the composed
            # "You've hit your weekly limit · resets <t>" notice) is
            # gated on claude.ai OAuth scopes inside the binary and is
            # UNREACHABLE under this harness's bearer-token auth — CC
            # ignores the unified headers and soft-retries any 429.
            # The reachable spoof: 429/rate_limit_error + a low
            # CLAUDE_CODE_MAX_RETRIES in the worker env → retries
            # exhaust → real StopFailure with error="rate_limit" and
            # last_assistant_message="API Error: Request rejected
            # (429) · <error_text>".
            return self._json(int(ctl.get("status", 500)),
                              {"type": "error",
                               "error": {"type": ctl.get("error_type", "api_error"),
                                         "message": ctl.get("error_text", "mock error")}},
                              headers=ctl.get("headers"))

        if not wants_stream:
            # Non-streaming JSON Messages response.
            return self._json_message(req, ctl)
        return self._stream_messages(req, ctl)

    # ---- non-streaming -----------------------------------------------------
    def _json_message(self, req, ctl):
        model = req.get("model", "claude-mock")
        content = self._content_blocks(ctl)
        stop = "tool_use" if ctl.get("mode") == "tool_use" else "end_turn"
        self._json(200, {
            "id": "msg_mock_0001", "type": "message", "role": "assistant",
            "model": model, "content": content,
            "stop_reason": stop, "stop_sequence": None,
            "usage": usage_block(ctl, 5),
        })

    def _content_blocks(self, ctl):
        if ctl.get("mode") == "tool_use":
            tool = ctl.get("tool") or {"name": "Bash", "input": {"command": "true"}}
            return [{"type": "tool_use", "id": "toolu_mock_0001",
                     "name": tool.get("name", "Bash"),
                     "input": tool.get("input", {})}]
        return [{"type": "text", "text": ctl.get("text", DEFAULT_TEXT)}]

    # ---- structured output (session-title / UI-hint generation) ------------
    def _fill_schema(self, schema, ctl):
        """Produce a minimal JSON object satisfying `schema`. Every string
        property is filled with the control knob `session_title` so CC's
        session-title call (schema `{title: string}`) gets that text as the
        session label. Falls back to `{title: <session_title>}` for an empty
        schema. Generic so any future structured-output call is satisfied."""
        value = ctl.get("session_title", "Mock session: harness exploration")
        props = schema.get("properties") if isinstance(schema, dict) else None
        obj = {}
        if isinstance(props, dict):
            for name, spec in props.items():
                t = spec.get("type") if isinstance(spec, dict) else None
                obj[name] = value if t == "string" else (
                    [] if t == "array" else {} if t == "object" else None)
        if not obj:
            obj = {"title": value}
        return json.dumps(obj)

    def _respond_structured(self, req, ctl, schema, wants_stream):
        text = self._fill_schema(schema, ctl)
        log("  -> session-title (structured): {}".format(text))
        self._respond_with_text(req, ctl, text, wants_stream)

    # ---- prompt suggestion (input-box autosuggest) -------------------------
    def _is_suggestion_request(self, req):
        """Claude Code's autosuggest call appends a final user message tagged
        `[SUGGESTION MODE: …]` (same system prompt as the turn, no schema). We
        key off that marker in the last user message."""
        msgs = req.get("messages") or []
        if not msgs:
            return False
        last = msgs[-1]
        if last.get("role") != "user":
            return False
        content = last.get("content")
        if isinstance(content, list):
            text = " ".join(b.get("text", "") for b in content
                            if isinstance(b, dict) and b.get("type") == "text")
        else:
            text = content if isinstance(content, str) else ""
        return "SUGGESTION MODE" in text

    def _respond_with_text(self, req, ctl, text, wants_stream):
        """Emit `text` as a complete assistant message (JSON or SSE stream),
        respecting the warm-cache `usage_block`. Shared by the session-title
        and prompt-suggestion paths — both just need to return plain text."""
        model = req.get("model", "claude-mock")
        if not wants_stream:
            return self._json(200, {
                "id": "msg_mock_aux", "type": "message", "role": "assistant",
                "model": model,
                "content": [{"type": "text", "text": text}],
                "stop_reason": "end_turn", "stop_sequence": None,
                "usage": usage_block(ctl, 5),
            })
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(ev, data):
            self.wfile.write(sse(ev, data))
            self.wfile.flush()

        try:
            self._emit_message_start(emit, model, ctl)
            emit("content_block_start", {
                "type": "content_block_start", "index": 0,
                "content_block": {"type": "text", "text": ""}})
            emit("content_block_delta", {
                "type": "content_block_delta", "index": 0,
                "delta": {"type": "text_delta", "text": text}})
            emit("content_block_stop", {"type": "content_block_stop", "index": 0})
            self._emit_message_stop(emit, "end_turn")
        except OSError:
            log("  (client disconnected during aux response)")

    # ---- streaming (SSE) ---------------------------------------------------
    def _stream_messages(self, req, ctl):
        model = req.get("model", "claude-mock")
        mode = ctl.get("mode", "text")
        delay_ms = int(ctl.get("delay_ms", 0) or 0)
        drip_ms = int(ctl.get("drip_ms", 0) or 0)

        # SSE under HTTP/1.1 carries no Content-Length, so we frame the
        # body by closing the connection at message_stop. Without this
        # the SDK waits for EOF forever (keep-alive) -> client hang.
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(ev, data):
            try:
                self.wfile.write(sse(ev, data))
                self.wfile.flush()
            except (BrokenPipeError, OSError):
                raise

        if delay_ms:
            time.sleep(delay_ms / 1000.0)

        try:
            self._emit_message_start(emit, model, ctl)
            if mode == "tool_use":
                self._emit_tool_use(emit, ctl)
                self._emit_message_stop(emit, "tool_use")
                return
            # text + hang share the text-streaming path.
            self._emit_text(emit, ctl, drip_ms, hang=(mode == "hang"))
            if mode == "hang":
                # Never finish: hold the stream open so claude stays
                # in the busy/spinner state indefinitely. The scenario
                # asserts sticky-state detection, then tears us down.
                hold = int(ctl.get("hang_seconds", 3600) or 3600)
                time.sleep(hold)
                return
            self._emit_message_stop(emit, "end_turn")
        except OSError:
            # Client hung up (scenario killed the pane / interrupted).
            log("  (client disconnected mid-stream)")

    def _emit_message_start(self, emit, model, ctl):
        emit("message_start", {
            "type": "message_start",
            "message": {
                "id": "msg_mock_0001", "type": "message", "role": "assistant",
                "model": model, "content": [], "stop_reason": None,
                "stop_sequence": None,
                "usage": usage_block(ctl, 1),
            },
        })

    def _emit_text(self, emit, ctl, drip_ms, hang):
        text = ctl.get("text", DEFAULT_TEXT)
        emit("content_block_start", {
            "type": "content_block_start", "index": 0,
            "content_block": {"type": "text", "text": ""},
        })
        # Drip word-by-word when drip_ms>0 so a busy window is visible to
        # pane-state.sh (the `↑ N tokens` spinner renders while the
        # request is in flight). Otherwise emit the whole text at once.
        chunks = text.split(" ") if drip_ms else [text]
        for i, chunk in enumerate(chunks):
            piece = chunk if i == 0 else " " + chunk
            emit("content_block_delta", {
                "type": "content_block_delta", "index": 0,
                "delta": {"type": "text_delta", "text": piece},
            })
            if drip_ms:
                time.sleep(drip_ms / 1000.0)
        if hang:
            return  # leave the block open; caller holds the connection
        emit("content_block_stop", {"type": "content_block_stop", "index": 0})

    def _emit_tool_use(self, emit, ctl):
        tool = ctl.get("tool") or {"name": "Bash", "input": {"command": "true"}}
        emit("content_block_start", {
            "type": "content_block_start", "index": 0,
            "content_block": {"type": "tool_use", "id": "toolu_mock_0001",
                              "name": tool.get("name", "Bash"), "input": {}},
        })
        emit("content_block_delta", {
            "type": "content_block_delta", "index": 0,
            "delta": {"type": "input_json_delta",
                      "partial_json": json.dumps(tool.get("input", {}))},
        })
        emit("content_block_stop", {"type": "content_block_stop", "index": 0})

    def _emit_message_stop(self, emit, stop_reason):
        emit("message_delta", {
            "type": "message_delta",
            "delta": {"stop_reason": stop_reason, "stop_sequence": None},
            "usage": {"output_tokens": 5},
        })
        emit("message_stop", {"type": "message_stop"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    try:
        open(LOG_PATH, "w").close()  # truncate per run
    except OSError:
        pass
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    actual_port = httpd.server_address[1]
    # Advertise the bound port so a caller that passed 0 can discover it.
    port_file = os.environ.get("MOCK_PORT_FILE")
    if port_file:
        with open(port_file, "w") as fh:
            fh.write(str(actual_port))
    log("MOCK listening on 127.0.0.1:{} (control={})".format(actual_port, CONTROL_PATH))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
