"""
Codex Stream Guard Proxy
~~~~~~~~~~~~~~~~~~~~~~~~
Sits between new-api and chatgpt.com.  Buffers the upstream SSE stream and
only forwards it to the client once ``response.completed`` is seen.  If the
stream breaks before that event arrives the proxy returns **502** so that
new-api's RETRY_TIMES / status_code_mapping can kick in and retry on another
channel.

When the buffer exceeds PASSTHROUGH_BYTES or PASSTHROUGH_SECS the proxy
switches to *passthrough* mode and streams events directly to the client.
"""

import io
import os
import time
import logging

from flask import Flask, Response, request
from curl_cffi import requests as cffi_requests

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
UPSTREAM = os.getenv("UPSTREAM_URL", "https://chatgpt.com")
PROXY_URL = os.getenv("PROXY_URL", "")          # e.g. http://resin:2260
PASSTHROUGH_BYTES = int(os.getenv("PASSTHROUGH_BYTES", 512 * 1024))  # 512 KB
PASSTHROUGH_SECS = int(os.getenv("PASSTHROUGH_SECS", 60))           # 60 s
READ_TIMEOUT = int(os.getenv("READ_TIMEOUT", 300))                  # 5 min

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("codex-proxy")

# Headers we copy from the inbound request to the upstream request.
FORWARD_HEADERS = {
    "authorization", "chatgpt-account-id", "content-type",
    "accept", "openai-sentinel-chat-requirements-token",
    "openai-sentinel-proof-token", "openai-sentinel-turnstile-token",
    "oai-device-id", "oai-language",
}

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.route("/__codex_proxy_health")
def health():
    return "ok", 200


# ---------------------------------------------------------------------------
# Catch-all proxy
# ---------------------------------------------------------------------------

@app.route("/", defaults={"path": ""}, methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
@app.route("/<path:path>", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
def proxy(path):
    upstream_url = f"{UPSTREAM.rstrip('/')}/{path}"
    if request.query_string:
        upstream_url += f"?{request.query_string.decode()}"

    # Build upstream headers
    headers = {}
    for key, value in request.headers:
        if key.lower() in FORWARD_HEADERS:
            headers[key] = value

    body = request.get_data()
    method = request.method

    proxies = {"https": PROXY_URL, "http": PROXY_URL} if PROXY_URL else None

    is_stream_request = "text/event-stream" in request.headers.get("Accept", "")

    try:
        resp = cffi_requests.request(
            method=method,
            url=upstream_url,
            headers=headers,
            data=body if body else None,
            proxies=proxies,
            impersonate="chrome",
            stream=is_stream_request,
            timeout=READ_TIMEOUT,
        )
    except Exception as e:
        log.error("upstream connect failed: %s", e)
        return Response(f'{{"error": "upstream connect failed: {e}"}}', status=502,
                        content_type="application/json")

    # Non-streaming: pass through directly
    if not is_stream_request:
        excluded = {"content-encoding", "transfer-encoding", "content-length", "connection"}
        resp_headers = [(k, v) for k, v in resp.headers.items() if k.lower() not in excluded]
        return Response(resp.content, status=resp.status_code, headers=resp_headers)

    # -------------------------------------------------------------------
    # SSE streaming with buffer-then-flush / passthrough logic
    # -------------------------------------------------------------------
    return _handle_sse(resp)


def _handle_sse(upstream_resp):
    """Buffer SSE events until response.completed, then flush to client.

    If the buffer grows past PASSTHROUGH_BYTES or PASSTHROUGH_SECS, switch to
    passthrough mode (stream directly).  If the upstream dies before
    response.completed *and* we haven't entered passthrough, return 502.
    """

    def generate():
        buf = io.BytesIO()
        started = time.monotonic()
        completed = False
        passthrough = False

        try:
            for chunk in upstream_resp.iter_content(chunk_size=4096):
                if not chunk:
                    continue

                if passthrough:
                    yield chunk
                    if b"response.completed" in chunk:
                        completed = True
                    continue

                buf.write(chunk)

                # Check for completion while still buffering
                if b"response.completed" in chunk:
                    completed = True
                    yield buf.getvalue()
                    return

                # Switch to passthrough if buffer too large or too old
                elapsed = time.monotonic() - started
                if buf.tell() >= PASSTHROUGH_BYTES or elapsed >= PASSTHROUGH_SECS:
                    log.info("switching to passthrough (buf=%d bytes, elapsed=%.1fs)",
                             buf.tell(), elapsed)
                    passthrough = True
                    yield buf.getvalue()
                    buf = None  # free memory

        except Exception as e:
            log.warning("upstream stream error: %s", e)
            # If still buffering, we haven't sent anything yet — abort
            if not passthrough:
                return
            # In passthrough we already committed to 200, nothing we can do
            return

        # Stream ended normally without response.completed
        if not completed and not passthrough:
            log.warning("stream ended without response.completed (buf=%d bytes)",
                        buf.tell() if buf else 0)
            return  # generator yields nothing → _handle_sse returns 502

        # Passthrough mode: stream ended (with or without completed)
        if passthrough and not completed:
            log.warning("passthrough stream ended without response.completed")

    # We need to consume the generator to decide the status code.
    # Collect all yielded data first.
    chunks = list(generate())

    if not chunks:
        # Nothing was yielded → stream broke before completion in buffer mode
        log.warning("returning 502 to trigger new-api retry")
        return Response(
            '{"error": "upstream stream closed before response.completed"}',
            status=502,
            content_type="application/json",
        )

    # We have data — stream it back as 200
    excluded = {"content-encoding", "transfer-encoding", "content-length", "connection"}
    resp_headers = [(k, v) for k, v in upstream_resp.headers.items()
                    if k.lower() not in excluded]

    def replay():
        for c in chunks:
            yield c

    return Response(replay(), status=200, headers=resp_headers,
                    content_type="text/event-stream")
