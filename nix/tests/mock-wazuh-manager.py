#!/usr/bin/env python3
"""Minimal mock of the Wazuh manager REST API, for the NixOS VM test.

It implements only the endpoints that the test exercises:
POST /security/user/authenticate, GET / and GET /agents.
"""

import base64
import json
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

USER = "wazuh-mcp"
PASSWORD = "mock-manager-password"
TOKEN = "mock-manager-token"

AGENTS = [
    {"id": "000", "name": "wazuh-manager", "status": "active", "ip": "127.0.0.1", "version": "Wazuh v4.14.8"},
    {"id": "001", "name": "web01", "status": "active", "ip": "192.0.2.10", "version": "Wazuh v4.14.8"},
]


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _bearer_ok(self):
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/security/user/authenticate":
            expected = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
            if self.headers.get("Authorization") != expected:
                return self._send(401, {"title": "Unauthorized", "detail": "Invalid credentials"})
            return self._send(200, {"data": {"token": TOKEN}, "error": 0})
        self._send(404, {"title": "Not Found"})

    def do_GET(self):
        if not self._bearer_ok():
            return self._send(401, {"title": "Unauthorized"})
        path = urlparse(self.path).path
        if path == "/":
            return self._send(
                200,
                {
                    "data": {
                        "title": "Wazuh API REST",
                        "api_version": "4.14.8",
                        "revision": 1,
                        "license_name": "GPL 2.0",
                        "hostname": "wazuh",
                    },
                    "error": 0,
                },
            )
        if path == "/agents":
            return self._send(
                200,
                {
                    "data": {
                        "affected_items": AGENTS,
                        "total_affected_items": len(AGENTS),
                        "total_failed_items": 0,
                        "failed_items": [],
                    },
                    "message": "All selected agents information was returned",
                    "error": 0,
                },
            )
        self._send(404, {"title": "Not Found"})


def main():
    cert, key, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
