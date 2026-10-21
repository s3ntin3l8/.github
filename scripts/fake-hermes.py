#!/usr/bin/env python3
"""A fake Hermes API server, for exercising hermes-review.yml without Hermes.

The workflow's "Run Hermes" step and the "Check for an in-flight review"
step both talk to the Hermes API. This server answers the handful of
endpoints they use, with the state the test drives:

    POST /v1/runs            -> 202 {"run_id", "status", "replayed"}
    GET  /v1/runs/<id>       -> 200 {"run_id", "status"}
    POST /v1/runs/<id>/stop  -> 200 {"status": "stopping"}

Usage: fake-hermes.py <port> [json-state]

    json-state keys: run_status (what GET /v1/runs/<id> answers),
                     dispatch_code (what POST /v1/runs answers),
                     request_log (a file to append the received requests to)

The received requests are appended to request_log as one JSON object per
line, so a test can assert on the idempotency key, the session id and the
body the workflow actually sent.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {
    "run_status": "running",
    # Per-run statuses, e.g. {"run_dead": "failed"}; run_status is the
    # fallback for any run id not named here.
    "run_statuses": {},
    "dispatch_code": 202,
    # A sequence of dispatch codes, e.g. [409, 202]: the first dispatch
    # answers 409, the second 202. dispatch_code is the fallback.
    "dispatch_codes": [],
    # The error code a 409 carries: "idempotency_key_conflict" (the key holds a
    # different body) or "admission_conflict" (the session refused the turn).
    "conflict_code": "idempotency_key_conflict",
    # What POST /v1/chat/completions (the legacy path) answers.
    "legacy_code": 200,
    "request_log": "",
}
DISPATCHES = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _record(self, entry):
        path = STATE.get("request_log")
        if not path:
            return
        with open(path, "a") as fh:
            fh.write(json.dumps(entry) + "\n")

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/v1/runs/"):
            run_id = self.path.rsplit("/", 1)[-1]
            self._record({"method": "GET", "path": self.path})
            if run_id == "unknown-run":
                self._send(404, {"error": "not found"})
                return
            status = STATE.get("run_statuses", {}).get(run_id, STATE["run_status"])
            self._send(200, {"run_id": run_id, "status": status})
            return
        self._send(404, {"error": "nope"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode() if length else ""
        if self.path.endswith("/stop"):
            run_id = self.path.split("/v1/runs/")[1].split("/")[0]
            self._record({"method": "POST", "path": self.path, "run_id": run_id})
            self._send(200, {"run_id": run_id, "status": "stopping"})
            return
        if self.path == "/v1/chat/completions":
            # The legacy path. It answers the refusal the caller has to notice:
            # a 409 means Hermes' session authority refused the turn.
            self._record({
                "method": "POST",
                "path": self.path,
                "session_id": self.headers.get("X-Hermes-Session-Id"),
                "body": json.loads(raw) if raw else None,
            })
            code = STATE["legacy_code"]
            if code == 409:
                self._send(409, {"error": {"message": "admission_conflict",
                                           "code": STATE["conflict_code"]}})
                return
            self._send(code, {"id": "chatcmpl-probe", "object": "chat.completion"})
            return
        if self.path == "/v1/runs":
            self._record({
                "method": "POST",
                "path": self.path,
                "idempotency_key": self.headers.get("Idempotency-Key"),
                "body": json.loads(raw) if raw else None,
            })
            codes = STATE.get("dispatch_codes") or []
            index = len(DISPATCHES)
            code = codes[index] if index < len(codes) else STATE["dispatch_code"]
            DISPATCHES.append(index)
            if code == 409:
                self._send(409, {"error": {"message": "Idempotency-Key was already used with a different request payload",
                                           "code": STATE["conflict_code"]}})
                return
            if code == 429:
                self._send(429, {"error": {"message": "Too many concurrent runs (max 10)",
                                           "code": "rate_limit_exceeded"}})
                return
            self._send(code, {"run_id": "run_new123", "status": "started", "replayed": False})
            return
        self._send(404, {"error": "nope"})


if __name__ == "__main__":
    port = int(sys.argv[1])
    if len(sys.argv) > 2:
        STATE.update(json.loads(sys.argv[2]))
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
