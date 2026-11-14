"""Authenticated loopback HTTP agent. All changes go through the isolated nft controller."""
import hmac
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from .enforcement import apply, fetch_ranges, normalize_countries, status
from .nft_rules import validate_policy
from .policy import PolicyValidationError, parse_feed

MAX_REQUEST_BYTES = 2048

def load_token(path: Path) -> bytes:
    if path.is_symlink() or path.stat().st_mode & 0o077:
        raise ValueError("Token file must be a private regular file (0600)")
    with path.open("rb") as stream:
        token = stream.read(4097).strip()
    if len(token) < 32 or len(token) > 4096 or any(c < 33 or c > 126 for c in token):
        raise ValueError("Invalid agent token")
    return token

def make_handler(token: bytes, feed_directory: Path, server_id: str, state_directory: Path | None = None):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", server_id):
        raise ValueError("Invalid server ID")
    if state_directory is None:
        if not feed_directory.is_dir():
            raise ValueError("Preview feed directory missing")
    elif not state_directory.is_dir():
        raise ValueError("State directory missing")

    class Handler(BaseHTTPRequestHandler):
        server_version = "4n6-country-agent/1"
        sys_version = ""

        def log_message(self, fmt, *args):
            return

        def respond(self, code, obj):
            data = json.dumps(obj, separators=(",", ":")).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def authorize(self):
            header = self.headers.get("Authorization", "")
            provided = header[7:].encode() if header.startswith("Bearer ") else b""
            if not hmac.compare_digest(provided, token):
                self.respond(401, {"error": "Unauthorized"})
                return False
            return True

        def do_GET(self):
            if self.path != "/v1/status":
                return self.respond(404, {"error": "Not found"})
            if not self.authorize():
                return
            try:
                info = status(state_directory) if state_directory else {
                    "countries": [], "enforcement_enabled":False, "applied":False, "mode":"preview-only"
                }
                self.respond(200, {"server_id":server_id, **info})
            except Exception:
                self.respond(503, {"error":"Status unavailable"})

        def do_POST(self):
            path = urlsplit(self.path)
            if path.path not in ("/v1/preview", "/v1/apply") or path.query:
                return self.respond(404, {"error":"Not found"})
            if not self.authorize():
                return
            if path.path == "/v1/apply" and state_directory is None:
                return self.respond(503, {"error":"Enforcement not installed"})
            length = self.headers.get("Content-Length", "")
            if not length.isdecimal() or not (1 <= int(length) <= MAX_REQUEST_BYTES):
                return self.respond(413, {"error":"Invalid request size"})
            if self.headers.get("Content-Type", "").split(";",1)[0].lower() != "application/json":
                return self.respond(415, {"error":"Expected JSON"})
            try:
                body = json.loads(self.rfile.read(int(length)))
                if not isinstance(body, dict) or set(body) != {"countries"}:
                    raise PolicyValidationError("Expected countries array")
                countries = normalize_countries(body["countries"])
                if path.path == "/v1/apply":
                    return self.respond(200, {"server_id":server_id, **apply(state_directory, countries)})
                if state_directory is None:
                    mapped = {
                        code: (
                            parse_feed((feed_directory / f"{code}.ipv4.txt").read_bytes(),4),
                            parse_feed((feed_directory / f"{code}.ipv6.txt").read_bytes(),6)
                        ) for code in countries
                    }
                else:
                    mapped = {code:fetch_ranges(code) for code in countries}
                if mapped:
                    v4,v6=validate_policy(mapped)
                    counts={"ipv4":len(v4),"ipv6":len(v6)}
                else:
                    counts={"ipv4":0,"ipv6":0}
                self.respond(200, {"server_id":server_id,"countries":countries,
                                   "counts":counts,"dry_run":True,"applied":False})
            except (ValueError, PolicyValidationError, TypeError):
                self.respond(400, {"error":"Invalid country selection or range data"})
            except Exception:
                self.respond(503, {"error":"Country policy operation failed"})

        def do_DELETE(self):
            self.respond(405, {"error":"Use the authenticated Apply endpoint with an empty country list"})

        do_PATCH = do_PUT = do_DELETE

    return Handler

def run(bind: str, port: int, token_path: Path, feed_directory: Path, server_id: str,
        state_directory: Path | None = None):
    if bind != "127.0.0.1" or not 1024 <= port <= 65535:
        raise ValueError("Bind only to IPv4 loopback and an unprivileged port")
    handler = make_handler(load_token(token_path), feed_directory, server_id, state_directory)
    with ThreadingHTTPServer((bind, port), handler) as server:
        server.serve_forever()
