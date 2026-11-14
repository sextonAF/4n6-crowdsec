import http.client
import json
import os
import stat
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

from country_agent.http_api import make_handler, load_token, run

TOKEN = b"Q" * 64

class ReadOnlyAgentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        base = Path(cls.temp.name)
        (base / "CN.ipv4.txt").write_bytes(b"1.1.1.0/24\n")
        (base / "CN.ipv6.txt").write_bytes(b"2606:4700::/32\n")
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(TOKEN, base, "gigahost-no"))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)
        cls.temp.cleanup()

    def request(self, method, path, payload=None, authenticated=True, content_type="application/json"):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        headers = {"Content-Type": content_type}
        if authenticated:
            headers["Authorization"] = "Bearer " + TOKEN.decode()
        body = json.dumps(payload) if payload is not None else None
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        code = response.status
        data = json.loads(response.read())
        connection.close()
        return code, data

    def test_status_authenticated(self):
        code, data = self.request("GET", "/v1/status")
        self.assertEqual(code, 200)
        self.assertFalse(data["enforcement_enabled"])
        self.assertFalse(data["applied"])

    def test_status_rejects_unauthenticated(self):
        self.assertEqual(self.request("GET", "/v1/status", authenticated=False)[0], 401)

    def test_preview_authenticated(self):
        code, data = self.request("POST", "/v1/preview", {"country": "CN"})
        self.assertEqual(code, 200)
        self.assertEqual(data["ipv4"]["cidr_count"], 1)
        self.assertFalse(data["applied"])

    def test_preview_rejects_unauthenticated(self):
        self.assertEqual(self.request("POST", "/v1/preview", {"country": "CN"}, False)[0], 401)

    def test_preview_rejects_unknown_country(self):
        self.assertEqual(self.request("POST", "/v1/preview", {"country": "ZZ"})[0], 400)

    def test_preview_rejects_unexpected_fields(self):
        self.assertEqual(self.request("POST", "/v1/preview", {"country": "CN", "command": "flush"})[0], 400)

    def test_other_methods_disabled(self):
        self.assertEqual(self.request("DELETE", "/v1/preview")[0], 405)

    def test_missing_feed_does_not_write(self):
        self.assertEqual(self.request("POST", "/v1/preview", {"country": "RU"})[0], 503)

    def test_loopback_only(self):
        with self.assertRaises(ValueError):
            run("0.0.0.0", 14110, Path("missing"), Path("missing"), "gigahost-no")

    def test_token_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            path.write_bytes(TOKEN)
            os.chmod(path, 0o644)
            with self.assertRaises(ValueError):
                load_token(path)
            os.chmod(path, 0o600)
            self.assertEqual(load_token(path), TOKEN)
