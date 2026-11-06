#!/usr/bin/env python3
"""Spec for the StreamCpp body the sidecar builds from a Neovim request.

    uv run --with 'httpx[http2]' --with cryptography test/request_body_spec.py

Runs the real sidecar's complete() against a synthesized Cursor install and a
local server standing in for StreamCpp, then asserts the body it posted.
Cursor fills linterErrors from Monaco markers, so its positions are 1-indexed
lines and columns; the Neovim side sends 0-indexed diagnostics.
"""
import json
import os
import struct
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "test"))
import fake_cursor_home  # noqa: E402

_fails = []


def check(name, got, want=True):
    ok = got == want
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    if not ok:
        print(f"       got  {got!r}\n       want {want!r}")
        _fails.append(name)


bodies = []


class StreamCpp(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["content-length"]))
        (n,) = struct.unpack(">I", raw[1:5])
        bodies.append(json.loads(raw[5 : 5 + n]))
        self.send_response(200)
        self.send_header("content-length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


with tempfile.TemporaryDirectory() as td:
    cursor_dir = Path(td) / "Cursor"
    fake_cursor_home.build(cursor_dir)
    os.environ["CURSOR_CONFIG_DIR"] = str(cursor_dir)
    os.environ.pop("CURSOR_STATE_DB_PATH", None)
    import sidecar  # noqa: E402

    server = ThreadingHTTPServer(("127.0.0.1", 0), StreamCpp)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    sidecar.STREAM_URL = f"http://127.0.0.1:{server.server_address[1]}/aiserver.v1.AiService/StreamCpp"

    sidecar.complete(
        {
            "id": 1,
            "path": "src/a.ts",
            "content": "import * as x from \"x\";\nimport { Unowned } from \n",
            "line": 1,
            "col": 24,
            "language": "typescript",
            "linter_errors": {
                "path": "src/a.ts",
                "errors": [
                    {
                        "message": "'Unowned' is declared but its value is never read.",
                        "source": "ts",
                        "severity": 4,
                        "range": {"sl": 1, "sc": 9, "el": 1, "ec": 16},
                    }
                ],
            },
        }
    )
    server.shutdown()

check("one StreamCpp request posted", len(bodies), 1)
lint = bodies[0].get("linterErrors", {}) if bodies else {}
check(
    "linter range is sent 1-indexed, as Cursor sends Monaco markers",
    [e.get("range") for e in lint.get("errors", [])],
    [{"startPosition": {"line": 2, "column": 10}, "endPosition": {"line": 2, "column": 17}}],
)
check("cursor position stays 0-indexed", bodies[0]["currentFile"]["cursorPosition"] if bodies else None, {"line": 1, "column": 24})

print(f"\n{'FAILED: ' + ', '.join(_fails) if _fails else 'request body holds'}")
sys.exit(1 if _fails else 0)
