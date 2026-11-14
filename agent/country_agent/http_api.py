"""Loopback-only authenticated read-only HTTP service for GeoIP previews.

No nftables operations, filesystem writes, outbound network or subprocess calls.
"""
from __future__ import annotations

import hmac
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from .policy import PolicyValidationError, preview_from_files, validate_country


MAX_REQUEST_BYTES = 2048
MAX_TOKEN_BYTES = 4096


def load_token(path: Path) -> bytes:
    """Read a pre-provisioned secret, never print it or store it in the repository."""
    if path.is_symlink():
        raise ValueError("Token file must not be a symbolic link")
    info = path.stat()
    if (info.st_mode & 0o077) != 0:
        raise ValueError("Token file permissions must be 0600 or stricter")
    with path.open("rb") as stream:
        token = stream.read(MAX_TOKEN_BYTES + 1).strip()
    if len(token) < 32 or len(token) > MAX_TOKEN_BYTES or any(char < 33 or char > 126 for char in token):
        raise ValueError("Token must contain 32–4096 printable non-whitespace bytes")
    return token


def make_handler(token: bytes, feed_directory: Path, server_id: str):
    """Create a handler with immutable configuration supplied at service startup."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", server_id):
        raise ValueError("Invalid server ID")
    feed_directory = feed_directory.resolve(strict=True)
    if not feed_directory.is_dir():
        raise ValueError("Feed directory must be a directory")

    class Handler(BaseHTTPRequestHandler):
        server_version = "4n6-country-preview/0.1"
        sys_version = ""

        def log_message(self, format, *args):
            # Never log Authorization headers or request bodies.
            return

        def respond(self, status: int, payload: dict):
            encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def authenticated(self) -> bool:
            value = self.headers.get("Authorization", "")
            prefix = "Bearer "
            candidate = value[len(prefix):].encode("utf-8") if value.startswith(prefix) else b""
            if not hmac.compare_digest(candidate, token):
                self.respond(401, {"error": "Unauthorized"})
                return False
            return True

        def do_GET(self):
            if urlsplit(self.path).path != "/v1/status" or urlsplit(self.path).query:
                self.respond(404, {"error": "Not found"})
                return
            if not self.authenticated():
                return
            self.respond(200, {
                "server_id": server_id,
                "mode": "preview-only",
                "enforcement_enabled": False,
                "applied": False,
                "agent_version": 1,
            })

        def do_POST(self):
            if urlsplit(self.path).path != "/v1/preview" or urlsplit(self.path).query:
                self.respond(404, {"error": "Not found"})
                return
            if not self.authenticated():
                return
            length_str = self.headers.get("Content-Length", "")
            if not length_str.isdecimal() or not (1 <= int(length_str) <= MAX_REQUEST_BYTES):
                self.respond(413, {"error": "Invalid request size"})
                return
            if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
                self.respond(415, {"error": "Expected application/json"})
                return
            try:
                payload = json.loads(self.rfile.read(int(length_str)))
                if not isinstance(payload, dict) or set(payload) != {"country"}:
                    raise ValueError("Only 'country' is accepted")
                code = validate_country(payload["country"])
                result = preview_from_files(
                    code,
                    feed_directory / f"{code}.ipv4.txt",
                    feed_directory / f"{code}.ipv6.txt",
                )
            except (ValueError, PolicyValidationError, UnicodeError) as exc:
                self.respond(400, {"error": "Invalid country or request"})
                return
            except OSError:
                self.respond(503, {"error": "GeoIP feed unavailable"})
                return
            self.respond(200, {"server_id": server_id, **result})

        def do_PUT(self):
            self.respond(405, {"error": "Read-only agent"})

        do_PATCH = do_DELETE = do_PUT

    return Handler


def run(bind: str, port: int, token_path: Path, feed_directory: Path, server_id: str):
    if bind not in ("127.0.0.1", "::1"):
        raise ValueError("Agent must bind to a loopback address")
    if not (1024 <= port <= 65535):
        raise ValueError("Agent requires an unprivileged TCP port")
    token = load_token(token_path)
    handler = make_handler(token, feed_directory, server_id)
    with ThreadingHTTPServer((bind, port), handler) as server:
        server.serve_forever()
