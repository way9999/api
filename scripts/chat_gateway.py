#!/usr/bin/env python3
import argparse
import http.client
import json
import mimetypes
import os
import posixpath
import socketserver
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlencode, urlsplit

ROOT = Path(__file__).resolve().parents[1]
CHAT_DIR = ROOT / "chat-ui"
INJECT_SNIPPET = b'<script src="/chat/home-entry.js?v=20260317-utf8-2"></script></body>'
UTF8_TYPES = {
    "text/html",
    "text/css",
    "text/plain",
    "application/javascript",
    "text/javascript",
    "application/json",
    "image/svg+xml",
}

HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


class GatewayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    backend_host = "127.0.0.1"
    backend_port = 3000

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def do_PUT(self):
        self.handle_request()

    def do_PATCH(self):
        self.handle_request()

    def do_DELETE(self):
        self.handle_request()

    def do_OPTIONS(self):
        self.handle_request()

    def do_HEAD(self):
        self.handle_request()

    def handle_request(self):
        parsed = urlsplit(self.path)
        path = parsed.path or "/"

        if path == "/__chat_gateway_health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", "2")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(b"OK")
            return

        if path == "/chat":
            self.send_response(302)
            self.send_header("Location", "/chat/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if path.startswith("/chat/"):
            self.serve_chat_asset(path)
            return

        if path == "/__chat_gateway_proxy":
            self.proxy_external(parsed)
            return

        self.proxy_to_backend(inject_home=path == "/")

    def serve_chat_asset(self, path: str):
        relative = path[len("/chat/"):] or "index.html"
        normalized = posixpath.normpath(relative).lstrip("/")
        target = (CHAT_DIR / normalized).resolve()

        if CHAT_DIR.resolve() not in target.parents and target != CHAT_DIR.resolve():
            self.send_error(403)
            return

        if target.is_dir():
            target = target / "index.html"

        if not target.exists() or not target.is_file():
            self.send_error(404)
            return

        ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        if ctype in UTF8_TYPES:
            ctype = f"{ctype}; charset=utf-8"
        data = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def proxy_to_backend(self, inject_home: bool):
        body = self.read_request_body()
        headers = self.build_upstream_headers()
        connection = http.client.HTTPConnection(self.backend_host, self.backend_port, timeout=600)
        try:
            connection.request(self.command, self.path, body=body, headers=headers)
            upstream = connection.getresponse()

            content_type = upstream.getheader("Content-Type", "")
            should_inject = inject_home and "text/html" in content_type.lower()

            if should_inject:
                payload = upstream.read()
                if b"</body>" in payload:
                    payload = payload.replace(b"</body>", INJECT_SNIPPET, 1)
                self.send_response(upstream.status, upstream.reason)
                self.copy_response_headers(upstream, override_length=len(payload))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(payload)
                return

            self.send_response(upstream.status, upstream.reason)
            self.copy_response_headers(upstream)
            self.end_headers()
            if self.command == "HEAD":
                return

            while True:
                chunk = upstream.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        finally:
            connection.close()

    def proxy_external(self, parsed):
        params = {}
        if parsed.query:
            for part in parsed.query.split("&"):
                if not part:
                    continue
                if "=" in part:
                    key, value = part.split("=", 1)
                else:
                    key, value = part, ""
                params[key] = value

        target_base = self.headers.get("X-Target-Base", "")
        target_path = self.headers.get("X-Target-Path", "")
        if not target_base or not target_path:
            self.send_json(400, {"error": "missing proxy target"})
            return

        base = urlsplit(target_base)
        if base.scheme not in {"http", "https"} or not base.netloc:
            self.send_json(400, {"error": "invalid target base"})
            return

        upstream_path = base.path.rstrip("/") + target_path
        if parsed.query:
            upstream_path = f"{upstream_path}?{parsed.query}"

        body = self.read_request_body()
        headers = self.build_external_headers(base)
        connection_cls = http.client.HTTPSConnection if base.scheme == "https" else http.client.HTTPConnection
        connection = connection_cls(base.netloc, timeout=600)
        try:
            connection.request(self.command, upstream_path, body=body, headers=headers)
            upstream = connection.getresponse()
            payload = upstream.read()
            self.send_response(upstream.status, upstream.reason)
            self.copy_external_response_headers(upstream, len(payload))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
        except Exception as exc:
            self.send_json(502, {"error": f"proxy request failed: {exc}"})
        finally:
            connection.close()

    def read_request_body(self):
        length = self.headers.get("Content-Length")
        if not length:
            return None
        try:
            size = int(length)
        except ValueError:
            return None
        return self.rfile.read(size)

    def build_upstream_headers(self):
        headers = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in HOP_BY_HOP_HEADERS:
                continue
            if lower == "host":
                headers[key] = f"{self.backend_host}:{self.backend_port}"
                continue
            headers[key] = value
        headers["Connection"] = "close"
        headers["X-Forwarded-For"] = self.client_address[0]
        headers["X-Forwarded-Proto"] = "http"
        return headers

    def build_external_headers(self, base):
        headers = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in HOP_BY_HOP_HEADERS or lower.startswith("x-target-"):
                continue
            if lower == "host":
                headers[key] = base.netloc
                continue
            headers[key] = value
        headers["Host"] = base.netloc
        headers["Connection"] = "close"
        return headers

    def copy_response_headers(self, upstream, override_length=None):
        sent_length = False
        for key, value in upstream.getheaders():
            lower = key.lower()
            if lower in HOP_BY_HOP_HEADERS:
                continue
            if lower == "content-length":
                if override_length is None:
                    self.send_header(key, value)
                    sent_length = True
                continue
            self.send_header(key, value)
        if override_length is not None:
            self.send_header("Content-Length", str(override_length))
            sent_length = True
        if not sent_length and upstream.getheader("Content-Length"):
            self.send_header("Content-Length", upstream.getheader("Content-Length"))

    def copy_external_response_headers(self, upstream, content_length):
        for key, value in upstream.getheaders():
            lower = key.lower()
            if lower in HOP_BY_HOP_HEADERS or lower == "content-length":
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(content_length))
        self.send_header("Access-Control-Allow-Origin", "*")

    def send_json(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def log_message(self, fmt, *args):
        print(f"[chat-gateway] {self.address_string()} - {fmt % args}")


class ReusableServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description="Serve /chat static assets and proxy the rest to new-api")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3080)
    parser.add_argument("--backend-host", default="127.0.0.1")
    parser.add_argument("--backend-port", type=int, default=3000)
    args = parser.parse_args()

    GatewayHandler.backend_host = args.backend_host
    GatewayHandler.backend_port = args.backend_port

    server = ReusableServer((args.host, args.port), GatewayHandler)
    print(f"[chat-gateway] listening on http://{args.host}:{args.port} -> http://{args.backend_host}:{args.backend_port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
