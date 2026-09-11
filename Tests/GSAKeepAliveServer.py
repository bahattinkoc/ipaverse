"""Run GSA transport regression tests against a loopback HTTP/1.1 server.

Usage: python3 Tests/GSAKeepAliveServer.py
No Apple requests, account credentials or persistent cookies are used.
"""

import http.server
import itertools
import json
import os
from pathlib import Path
import subprocess
import threading


class KeepAliveHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    connection_ids = itertools.count(1)

    def setup(self):
        super().setup()
        self.connection_id = next(self.connection_ids)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        response = json.dumps({
            "connection": self.connection_id,
            "body": body.decode("utf-8"),
            "cookie": self.headers.get("Cookie", ""),
            "fixture": self.headers.get("X-Fixture", ""),
        }).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.send_header("Set-Cookie", "gsa-fixture=retained; Path=/; HttpOnly")
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), KeepAliveHandler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        environment = os.environ.copy()
        environment["IPAVERSE_GSA_TEST_URL"] = f"http://127.0.0.1:{server.server_port}/"
        try:
            result = subprocess.run(
                ["bash", "scripts/test-anisette.sh"],
                cwd=Path(__file__).resolve().parent.parent,
                env=environment,
                timeout=120,
            )
        finally:
            server.shutdown()
            thread.join()
        raise SystemExit(result.returncode)
