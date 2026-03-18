#!/usr/bin/env python3
"""
Unified dashboard for GPT register, token extraction, channel import,
traffic monitoring, and account pool management.
"""

import base64
import glob
import hashlib
import json
import os
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from functools import wraps

from flask import Flask, jsonify, render_template, request
from flask_sock import Sock

app = Flask(__name__)
sock = Sock(app)

DASHBOARD_PWD = os.environ.get("GPT_REGISTER_DASHBOARD_PWD", "")
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/app/output")
AUTH_DIR = os.environ.get("AUTH_DIR", "/auth")
PROXY_URL = os.environ.get("PROXY_URL", "")
REG_MODE = os.environ.get("REG_MODE", "http")

MYSQL_HOST = os.environ.get("MYSQL_HOST", "mysql")
MYSQL_USER = os.environ.get("MYSQL_USER", "root")
MYSQL_PASS = os.environ.get("MYSQL_PASS", "")
MYSQL_DB = os.environ.get("MYSQL_DB", "newapi")

ONLINE_WINDOW_SECONDS = int(os.environ.get("DASHBOARD_ONLINE_WINDOW_SECONDS", "300"))
MAX_LOG_LINES = 2000

log_buffer = deque(maxlen=MAX_LOG_LINES)
log_lock = threading.Lock()
ws_clients = set()
ws_lock = threading.Lock()


def broadcast_log(line: str):
    with log_lock:
        log_buffer.append(line)
    dead = set()
    with ws_lock:
        for ws in ws_clients:
            try:
                ws.send(json.dumps({"type": "log", "data": line}))
            except Exception:
                dead.add(ws)
        ws_clients.difference_update(dead)


def broadcast_status():
    payload = json.dumps({"type": "status", "data": _build_status()})
    dead = set()
    with ws_lock:
        for ws in ws_clients:
            try:
                ws.send(payload)
            except Exception:
                dead.add(ws)
        ws_clients.difference_update(dead)


class RegisterProcess:
    def __init__(self):
        self.proc = None
        self.thread = None
        self.started_at = None
        self.lock = threading.Lock()

    def start(self, proxy: str = "", once: bool = False, mode: str = "", target: int = 0):
        with self.lock:
            if self.proc and self.proc.poll() is None:
                return False, "process already running"

            if mode == "manager":
                cmd = [sys.executable, "-u", "/app/manager.py"]
                if proxy:
                    cmd += ["--proxy", proxy]
                if target > 0:
                    cmd += ["--target", str(target)]
            else:
                script = "register_browser.py" if REG_MODE == "browser" else "register.py"
                cmd = [sys.executable, "-u", script]
                if proxy:
                    cmd += ["--proxy", proxy]
                if once:
                    cmd.append("--once")

            self.proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                cwd="/app",
            )
            self.started_at = time.time()
            self.thread = threading.Thread(target=self._reader, daemon=True)
            self.thread.start()
            broadcast_log(f"[dashboard] register process started (pid={self.proc.pid})")
            broadcast_status()
            return True, "started"

    def stop(self):
        with self.lock:
            if not self.proc or self.proc.poll() is not None:
                broadcast_status()
                return False, "process not running"

            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            broadcast_log("[dashboard] register process stopped")
            broadcast_status()
            return True, "stopped"

    def _reader(self):
        try:
            for line in self.proc.stdout:
                broadcast_log(line.rstrip("\n"))
        except Exception:
            pass
        finally:
            broadcast_log("[dashboard] register process exited")
            broadcast_status()

    @property
    def status(self):
        if self.proc and self.proc.poll() is None:
            return "running"
        return "stopped"


reg_process = RegisterProcess()


def require_auth(func):
    @wraps(func)
    def decorated(*args, **kwargs):
        if not DASHBOARD_PWD:
            return func(*args, **kwargs)
        token = request.headers.get("Authorization", "")
        if token == f"Bearer {DASHBOARD_PWD}":
            return func(*args, **kwargs)
        return jsonify({"error": "unauthorized"}), 401

    return decorated


def _get_db():
    import pymysql
    from pymysql.cursors import DictCursor

    return pymysql.connect(
        host=MYSQL_HOST,
        user=MYSQL_USER,
        password=MYSQL_PASS,
        database=MYSQL_DB,
        cursorclass=DictCursor,
    )


def _count_accounts():
    return len(glob.glob(os.path.join(OUTPUT_DIR, "token_*.json")))


def _count_injected():
    return len(glob.glob(os.path.join(AUTH_DIR, "codex-*.json")))


def _build_status():
    return {
        "status": reg_process.status,
        "registered": _count_accounts(),
        "injected": _count_injected(),
        "started_at": reg_process.started_at,
        "proxy": PROXY_URL,
        "reg_mode": REG_MODE,
        "auth_required": bool(DASHBOARD_PWD),
    }


def _load_json_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _decode_jwt_payload(token: str):
    if not token or "." not in token:
        return {}
    try:
        payload = token.split(".")[1]
        payload += "=" * ((4 - len(payload) % 4) % 4)
        return json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))
    except Exception:
        return {}


def _decode_channel_key(raw_key):
    if isinstance(raw_key, dict):
        return raw_key
    if not raw_key:
        return {}
    try:
        return json.loads(raw_key)
    except Exception:
        return {}


def _extract_plan(token_data: dict):
    if not token_data:
        return ""
    if token_data.get("plan"):
        return str(token_data.get("plan"))
    claims = _decode_jwt_payload(token_data.get("id_token", ""))
    auth_info = claims.get("https://api.openai.com/auth") or {}
    return str(auth_info.get("chatgpt_plan_type", ""))


def _format_ts(ts_value):
    if not ts_value:
        return ""
    try:
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(int(ts_value)))
    except Exception:
        return ""


def _merge_account_entry(target: dict, payload: dict):
    for key, value in payload.items():
        if value not in (None, "", [], {}):
            target[key] = value
    return target


def _empty_account(email=""):
    return {
        "email": email,
        "display_name": email.split("@")[0] if "@" in email else email,
        "plan": "",
        "expired": "",
        "created": "",
        "sources": [],
        "imported": False,
        "has_output_token": False,
        "has_auth_token": False,
        "requests_5m": 0,
        "requests_today": 0,
        "quota_today": 0,
        "used_quota": 0,
        "total_requests": 0,
        "active_users_5m": 0,
        "model_count": 0,
        "last_used_at": "",
        "last_used_at_ts": 0,
        "channel_status": 0,
    }


def _load_local_accounts():
    accounts = {}
    output_pattern = os.path.join(OUTPUT_DIR, "token_*.json")
    auth_pattern = os.path.join(AUTH_DIR, "codex-*.json")
    injected_marker = os.path.join(OUTPUT_DIR, ".injected")

    injected_set = set()
    if os.path.exists(injected_marker):
        try:
            with open(injected_marker, "r", encoding="utf-8") as f:
                injected_set = {line.strip() for line in f if line.strip()}
        except Exception:
            injected_set = set()

    for tf in sorted(glob.glob(output_pattern), key=os.path.getmtime, reverse=True):
        data = _load_json_file(tf)
        if not data:
            continue
        email = data.get("email") or os.path.basename(tf)
        key = email.lower()
        entry = accounts.setdefault(key, _empty_account(email))
        _merge_account_entry(
            entry,
            {
                "email": email,
                "display_name": email.split("@")[0] if "@" in email else email,
                "plan": _extract_plan(data),
                "expired": data.get("expired", ""),
                "created": time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(tf))),
                "token_type": data.get("type", ""),
            },
        )
        entry["has_output_token"] = True
        entry["imported"] = entry["imported"] or os.path.basename(tf) in injected_set
        if "output" not in entry["sources"]:
            entry["sources"].append("output")

    for af in sorted(glob.glob(auth_pattern), key=os.path.getmtime, reverse=True):
        data = _load_json_file(af)
        if not data:
            continue
        email = data.get("email") or os.path.basename(af)
        key = email.lower()
        entry = accounts.setdefault(key, _empty_account(email))
        _merge_account_entry(
            entry,
            {
                "email": email,
                "display_name": email.split("@")[0] if "@" in email else email,
                "plan": _extract_plan(data),
                "expired": data.get("expired", ""),
            },
        )
        entry["has_auth_token"] = True
        entry["imported"] = True
        if "auth" not in entry["sources"]:
            entry["sources"].append("auth")

    return accounts


def _build_monitor_payload():
    summary = {
        "active_now": 0,
        "requests_5m": 0,
        "requests_today": 0,
        "quota_today": 0,
        "channels_active": 0,
        "channels_total": 0,
        "pool_size": 0,
        "updated_at": int(time.time()),
        "window_seconds": ONLINE_WINDOW_SECONDS,
    }
    channels = []
    account_map = _load_local_accounts()

    try:
        conn = _get_db()
        with conn.cursor() as cur:
            cur.execute(
                f"""
                SELECT
                    COALESCE(COUNT(DISTINCT CASE
                        WHEN l.created_at >= UNIX_TIMESTAMP() - {ONLINE_WINDOW_SECONDS}
                        THEN CONCAT(COALESCE(l.username, ''), '|', COALESCE(l.token_name, ''), '|', COALESCE(l.ip, ''))
                    END), 0) AS active_now,
                    COALESCE(SUM(CASE WHEN l.created_at >= UNIX_TIMESTAMP() - {ONLINE_WINDOW_SECONDS} THEN 1 ELSE 0 END), 0) AS requests_5m,
                    COALESCE(SUM(CASE WHEN l.created_at >= UNIX_TIMESTAMP(CURDATE()) THEN 1 ELSE 0 END), 0) AS requests_today,
                    COALESCE(SUM(CASE WHEN l.created_at >= UNIX_TIMESTAMP(CURDATE()) THEN l.quota ELSE 0 END), 0) AS quota_today,
                    COALESCE(COUNT(DISTINCT CASE WHEN l.created_at >= UNIX_TIMESTAMP() - {ONLINE_WINDOW_SECONDS} THEN l.channel_id END), 0) AS channels_active,
                    COALESCE(COUNT(DISTINCT c.id), 0) AS channels_total
                FROM channels c
                LEFT JOIN logs l ON l.channel_id = c.id
                WHERE c.type = 57
                """
            )
            row = cur.fetchone() or {}
            summary.update(
                {
                    "active_now": int(row.get("active_now") or 0),
                    "requests_5m": int(row.get("requests_5m") or 0),
                    "requests_today": int(row.get("requests_today") or 0),
                    "quota_today": int(row.get("quota_today") or 0),
                    "channels_active": int(row.get("channels_active") or 0),
                    "channels_total": int(row.get("channels_total") or 0),
                }
            )

            cur.execute(
                f"""
                SELECT
                    c.id,
                    c.name,
                    c.status,
                    c.used_quota,
                    c.created_time,
                    c.models,
                    c.`key`,
                    c.setting,
                    c.`group`,
                    COALESCE(COUNT(l.id), 0) AS total_requests,
                    COALESCE(SUM(CASE WHEN l.created_at >= UNIX_TIMESTAMP() - {ONLINE_WINDOW_SECONDS} THEN 1 ELSE 0 END), 0) AS requests_5m,
                    COALESCE(SUM(CASE WHEN l.created_at >= UNIX_TIMESTAMP(CURDATE()) THEN 1 ELSE 0 END), 0) AS requests_today,
                    COALESCE(SUM(CASE WHEN l.created_at >= UNIX_TIMESTAMP(CURDATE()) THEN l.quota ELSE 0 END), 0) AS quota_today,
                    COALESCE(COUNT(DISTINCT CASE
                        WHEN l.created_at >= UNIX_TIMESTAMP() - {ONLINE_WINDOW_SECONDS}
                        THEN CONCAT(COALESCE(l.username, ''), '|', COALESCE(l.token_name, ''), '|', COALESCE(l.ip, ''))
                    END), 0) AS active_users_5m,
                    MAX(l.created_at) AS last_log_at
                FROM channels c
                LEFT JOIN logs l ON l.channel_id = c.id
                WHERE c.type = 57
                GROUP BY c.id, c.name, c.status, c.used_quota, c.created_time, c.models, c.`key`, c.setting, c.`group`
                ORDER BY COALESCE(MAX(l.created_at), c.created_time) DESC, c.id DESC
                """
            )
            rows = cur.fetchall() or []
        conn.close()
    except Exception as e:
        summary["db_error"] = str(e)
        rows = []

    for row in rows:
        token_data = _decode_channel_key(row.get("key"))
        email = token_data.get("email") or row.get("name") or f"channel-{row.get('id')}"
        display_name = row.get("name") or (email.split("@")[0] if "@" in email else email)
        plan = _extract_plan(token_data) or "unknown"
        models = row.get("models") or ""
        model_list = [part.strip() for part in models.split(",") if part.strip()]
        last_log_at = int(row.get("last_log_at") or 0)
        created_at = int(row.get("created_time") or 0)

        setting_data = {}
        try:
            setting_data = json.loads(row.get("setting") or "{}") if row.get("setting") else {}
        except Exception:
            pass

        item = {
            "id": int(row.get("id") or 0),
            "name": row.get("name") or display_name,
            "email": email,
            "display_name": display_name,
            "plan": plan,
            "status": int(row.get("status") or 0),
            "used_quota": int(row.get("used_quota") or 0),
            "requests_5m": int(row.get("requests_5m") or 0),
            "requests_today": int(row.get("requests_today") or 0),
            "quota_today": int(row.get("quota_today") or 0),
            "total_requests": int(row.get("total_requests") or 0),
            "active_users_5m": int(row.get("active_users_5m") or 0),
            "last_used_at_ts": last_log_at,
            "last_used_at": _format_ts(last_log_at),
            "created_at_ts": created_at,
            "created_at": _format_ts(created_at),
            "expired": token_data.get("expired", ""),
            "model_count": len(model_list),
            "models": model_list,
            "imported": True,
            "proxy": setting_data.get("proxy", ""),
            "group": row.get("group") or "",
        }
        channels.append(item)

        key = email.lower()
        entry = account_map.setdefault(key, _empty_account(email))
        _merge_account_entry(
            entry,
            {
                "email": email,
                "display_name": display_name,
                "plan": plan,
                "expired": token_data.get("expired", ""),
                "created": _format_ts(created_at),
                "channel_id": item["id"],
                "channel_name": item["name"],
                "channel_status": item["status"],
                "requests_5m": item["requests_5m"],
                "requests_today": item["requests_today"],
                "quota_today": item["quota_today"],
                "used_quota": item["used_quota"],
                "total_requests": item["total_requests"],
                "active_users_5m": item["active_users_5m"],
                "model_count": item["model_count"],
                "last_used_at": item["last_used_at"],
                "last_used_at_ts": item["last_used_at_ts"],
            },
        )
        entry["imported"] = True
        if "channel" not in entry["sources"]:
            entry["sources"].append("channel")

    accounts = sorted(
        account_map.values(),
        key=lambda item: (
            int(item.get("requests_5m") or 0),
            int(item.get("last_used_at_ts") or 0),
            item.get("email") or "",
        ),
        reverse=True,
    )
    summary["pool_size"] = len(accounts)
    return {"summary": summary, "channels": channels, "accounts": accounts}


def _load_accounts():
    return _build_monitor_payload()["accounts"]


@app.route("/")
def index():
    return render_template("index.html", auth_required=bool(DASHBOARD_PWD))


@app.route("/api/status")
@require_auth
def api_status():
    return jsonify(_build_status())


@app.route("/api/monitor")
@require_auth
def api_monitor():
    return jsonify(_build_monitor_payload())


@app.route("/api/start", methods=["POST"])
@require_auth
def api_start():
    body = request.get_json(silent=True) or {}
    proxy = body.get("proxy", PROXY_URL)
    once = body.get("once", False)
    mode = body.get("mode", "")
    target = int(body.get("target", 0))
    ok, message = reg_process.start(proxy=proxy, once=once, mode=mode, target=target)
    return jsonify({"ok": ok, "message": message})


@app.route("/api/stop", methods=["POST"])
@require_auth
def api_stop():
    ok, message = reg_process.stop()
    return jsonify({"ok": ok, "message": message})


@app.route("/api/inject", methods=["POST"])
@require_auth
def api_inject():
    try:
        result = subprocess.run(
            [sys.executable, "-u", "inject.py"],
            capture_output=True,
            text=True,
            cwd="/app",
            timeout=30,
        )
        output = result.stdout.strip()
        for line in output.split("\n"):
            if line:
                broadcast_log(line)
        return jsonify({"ok": True, "message": output or "inject complete"})
    except Exception as e:
        return jsonify({"ok": False, "message": str(e)})


@app.route("/api/accounts")
@require_auth
def api_accounts():
    return jsonify(_load_accounts())


@app.route("/api/upgrade", methods=["POST"])
@require_auth
def api_upgrade():
    body = request.get_json(silent=True) or {}
    token = body.get("token", "")
    channel_id = body.get("channel_id")
    card_number = body.get("card_number", "")
    card_expiry = body.get("card_expiry", "")
    card_cvc = body.get("card_cvc", "")
    billing_name = body.get("billing_name", "")

    if channel_id and not token:
        try:
            conn = _get_db()
            with conn.cursor() as cur:
                cur.execute("SELECT `key`, name FROM channels WHERE id=%s AND type=57", (channel_id,))
                row = cur.fetchone()
            conn.close()
            if row:
                token_data = _decode_channel_key(row.get("key"))
                token = token_data.get("access_token", "") or token_data.get("refresh_token", "")
                broadcast_log(f"[dashboard] loaded upgrade token from channel #{channel_id} ({row.get('name', '')})")
        except Exception as e:
            return jsonify({"ok": False, "message": f"failed to load channel token: {e}"})

    if not all([token, card_number, card_expiry, card_cvc, billing_name]):
        return jsonify(
            {
                "ok": False,
                "message": "missing required params: token, card_number, card_expiry, card_cvc, billing_name",
            }
        )

    cmd = [
        sys.executable,
        "-u",
        "upgrade_team.py",
        "--token",
        token,
        "--card-number",
        card_number,
        "--card-expiry",
        card_expiry,
        "--card-cvc",
        card_cvc,
        "--billing-name",
        billing_name,
    ]
    for key in (
        "billing_address",
        "billing_city",
        "billing_state",
        "billing_zip",
        "billing_country",
        "team_name",
    ):
        value = body.get(key, "")
        if value:
            cmd += [f"--{key.replace('_', '-')}", value]
    if PROXY_URL:
        cmd += ["--proxy", PROXY_URL]

    broadcast_log("[dashboard] starting team upgrade flow")
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            cwd="/app",
        )

        def _reader():
            for line in proc.stdout:
                broadcast_log(line.rstrip("\n"))
            broadcast_log("[dashboard] team upgrade flow finished")

        threading.Thread(target=_reader, daemon=True).start()
        return jsonify({"ok": True, "message": f"upgrade process started (pid={proc.pid})"})
    except Exception as e:
        return jsonify({"ok": False, "message": str(e)})


@app.route("/api/batch-upgrade", methods=["POST"])
@require_auth
def api_batch_upgrade():
    body = request.get_json(silent=True) or {}
    cards = body.get("cards", [])
    channel_ids = body.get("channel_ids", [])
    common = body.get("common", {})

    if not cards:
        return jsonify({"ok": False, "message": "missing cards"})
    if not channel_ids:
        return jsonify({"ok": False, "message": "missing channel_ids"})

    # card-channel pairing: round-robin
    pairs = []
    for i, cid in enumerate(channel_ids):
        card = cards[i % len(cards)]
        pairs.append((cid, card))

    def _run_batch():
        for idx, (cid, card) in enumerate(pairs):
            broadcast_log(f"[batch-upgrade] ({idx+1}/{len(pairs)}) upgrading channel #{cid}")
            try:
                conn = _get_db()
                with conn.cursor() as cur:
                    cur.execute("SELECT `key`, name FROM channels WHERE id=%s AND type=57", (cid,))
                    row = cur.fetchone()
                conn.close()
                if not row:
                    broadcast_log(f"[batch-upgrade] channel #{cid} not found, skipping")
                    continue
                token_data = _decode_channel_key(row.get("key"))
                token = token_data.get("access_token", "") or token_data.get("refresh_token", "")
                if not token:
                    broadcast_log(f"[batch-upgrade] channel #{cid} has no token, skipping")
                    continue

                cmd = [
                    sys.executable, "-u", "upgrade_team.py",
                    "--token", token,
                    "--card-number", card.get("card_number", ""),
                    "--card-expiry", card.get("card_expiry", ""),
                    "--card-cvc", card.get("card_cvc", ""),
                    "--billing-name", card.get("billing_name", common.get("billing_name", "")),
                ]
                for key in ("billing_address", "billing_city", "billing_state", "billing_zip", "billing_country", "team_name"):
                    value = card.get(key, "") or common.get(key, "")
                    if value:
                        cmd += [f"--{key.replace('_', '-')}", value]
                if PROXY_URL:
                    cmd += ["--proxy", PROXY_URL]

                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, cwd="/app")
                for line in proc.stdout:
                    broadcast_log(line.rstrip("\n"))
                proc.wait()
                broadcast_log(f"[batch-upgrade] channel #{cid} done (exit={proc.returncode})")
            except Exception as e:
                broadcast_log(f"[batch-upgrade] channel #{cid} error: {e}")
        broadcast_log(f"[batch-upgrade] all {len(pairs)} upgrades finished")

    threading.Thread(target=_run_batch, daemon=True).start()
    return jsonify({"ok": True, "message": f"batch upgrade started: {len(pairs)} channels"})


@app.route("/api/logs")
@require_auth
def api_logs():
    with log_lock:
        return jsonify(list(log_buffer))


@app.route("/api/extract-token", methods=["POST"])
@require_auth
def api_extract_token():
    body = request.get_json(silent=True) or {}
    email = body.get("email", "").strip()
    otp_code = body.get("otp_code", "").strip()
    step = body.get("step", "start")

    if not email:
        return jsonify({"ok": False, "message": "missing email"})

    proxy = PROXY_URL
    broadcast_log(f"[extract] token extraction for {email} (step={step})")

    try:
        from curl_cffi import requests as cffi_req
        import re as _re
        import secrets
        import time as _t
        import urllib.parse
        import urllib.request

        def b64url(raw):
            return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

        proxies = {"http": proxy, "https": proxy} if proxy else None
        auth_url_base = "https://auth.openai.com/oauth/authorize"
        token_url = "https://auth.openai.com/oauth/token"
        client_id = "app_EMoamEEZ73f0CkXaXp7hrann"
        redirect_uri = "http://localhost:1455/auth/callback"
        scope = "openid email profile offline_access"

        if step == "start":
            verifier = secrets.token_urlsafe(64)
            challenge = b64url(hashlib.sha256(verifier.encode()).digest())
            state = secrets.token_urlsafe(16)
            params = {
                "client_id": client_id,
                "response_type": "code",
                "redirect_uri": redirect_uri,
                "scope": scope,
                "state": state,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "prompt": "login",
                "id_token_add_organizations": "true",
                "codex_cli_simplified_flow": "true",
            }
            auth_url = f"{auth_url_base}?{urllib.parse.urlencode(params)}"

            session = cffi_req.Session(proxies=proxies, impersonate="chrome")
            for _ in range(8):
                try:
                    session.get(auth_url, timeout=15)
                    trace = session.get("https://cloudflare.com/cdn-cgi/trace", timeout=10).text
                    match = _re.search(r"^loc=(.+)$", trace, _re.MULTILINE)
                    loc = match.group(1) if match else "?"
                    if loc in ("CN", "HK", "TW", "SG"):
                        broadcast_log(f"[extract] region {loc}, retrying")
                        session = cffi_req.Session(proxies=proxies, impersonate="chrome")
                        continue
                    broadcast_log(f"[extract] region {loc}")
                    break
                except Exception:
                    session = cffi_req.Session(proxies=proxies, impersonate="chrome")
                    _t.sleep(1)

            did = session.cookies.get("oai-did")
            broadcast_log(f"[extract] did={did}")

            sentinel_resp = cffi_req.post(
                "https://sentinel.openai.com/backend-api/sentinel/req",
                headers={"origin": "https://sentinel.openai.com", "content-type": "text/plain;charset=UTF-8"},
                data=json.dumps({"p": "", "id": did, "flow": "authorize_continue"}),
                proxies=proxies,
                impersonate="chrome",
                timeout=15,
            )
            if sentinel_resp.status_code != 200:
                return jsonify({"ok": False, "message": f"sentinel failed: {sentinel_resp.status_code}"})
            sentinel = json.dumps(
                {
                    "p": "",
                    "t": "",
                    "c": sentinel_resp.json()["token"],
                    "id": did,
                    "flow": "authorize_continue",
                }
            )

            session.post(
                "https://auth.openai.com/api/accounts/authorize/continue",
                headers={
                    "referer": "https://auth.openai.com/log-in",
                    "accept": "application/json",
                    "content-type": "application/json",
                    "openai-sentinel-token": sentinel,
                },
                data=json.dumps({"username": {"value": email, "kind": "email"}, "screen_hint": "login"}),
            )

            otp_resp = session.post(
                "https://auth.openai.com/api/accounts/passwordless/send-otp",
                headers={
                    "referer": "https://auth.openai.com/log-in/password",
                    "accept": "application/json",
                    "content-type": "application/json",
                },
            )
            broadcast_log(f"[extract] otp sent: {otp_resp.status_code}")
            return jsonify(
                {
                    "ok": True,
                    "step": "need_otp",
                    "message": "otp sent",
                    "_verifier": verifier,
                    "_state": state,
                    "_cookies": dict(session.cookies),
                    "_auth_url": auth_url,
                }
            )

        if step == "otp" and otp_code:
            verifier = body.get("_verifier", "")
            state = body.get("_state", "")
            saved_cookies = body.get("_cookies", {})
            if not verifier or not state or not saved_cookies:
                return jsonify({"ok": False, "message": "missing session state, please restart"})

            session = cffi_req.Session(proxies=proxies, impersonate="chrome")
            for key, value in saved_cookies.items():
                session.cookies.set(key, value)

            code_resp = session.post(
                "https://auth.openai.com/api/accounts/email-otp/validate",
                headers={
                    "referer": "https://auth.openai.com/email-verification",
                    "accept": "application/json",
                    "content-type": "application/json",
                },
                data=json.dumps({"code": otp_code}),
            )
            broadcast_log(f"[extract] otp validate: {code_resp.status_code}")
            if code_resp.status_code != 200:
                return jsonify({"ok": False, "message": f"otp invalid or expired: {code_resp.text[:200]}"})

            auth_cookie = session.cookies.get("oai-client-auth-session")
            if not auth_cookie:
                return jsonify({"ok": False, "message": "auth cookie missing"})

            auth_json = json.loads(base64.b64decode(auth_cookie.split(".")[0]))
            workspaces = auth_json.get("workspaces", [])
            if not workspaces:
                return jsonify({"ok": False, "message": "no workspace found"})
            workspace_id = workspaces[0]["id"]
            broadcast_log(f"[extract] workspace={workspace_id}")

            select_resp = session.post(
                "https://auth.openai.com/api/accounts/workspace/select",
                headers={"content-type": "application/json"},
                data=json.dumps({"workspace_id": workspace_id}),
            )
            continue_url = select_resp.json().get("continue_url", "")
            if not continue_url:
                return jsonify({"ok": False, "message": "continue_url missing"})

            resp = session.get(continue_url, allow_redirects=False, timeout=15)
            for _ in range(5):
                location = resp.headers.get("Location", "")
                if not location or resp.status_code not in (301, 302, 303, 307, 308):
                    break
                next_url = urllib.parse.urljoin(resp.url, location)
                if "code=" in next_url and "state=" in next_url:
                    parsed = urllib.parse.urlparse(next_url)
                    qs = urllib.parse.parse_qs(parsed.query)
                    code = qs.get("code", [""])[0]

                    form = urllib.parse.urlencode(
                        {
                            "grant_type": "authorization_code",
                            "client_id": client_id,
                            "code": code,
                            "redirect_uri": redirect_uri,
                            "code_verifier": verifier,
                        }
                    ).encode()
                    req = urllib.request.Request(
                        token_url,
                        data=form,
                        method="POST",
                        headers={
                            "Content-Type": "application/x-www-form-urlencoded",
                            "Accept": "application/json",
                        },
                    )
                    with urllib.request.urlopen(req, timeout=30) as token_resp:
                        token_data = json.loads(token_resp.read())

                    claims = _decode_jwt_payload(token_data["id_token"])
                    now = int(_t.time())
                    token_obj = {
                        "id_token": token_data["id_token"],
                        "access_token": token_data["access_token"],
                        "refresh_token": token_data["refresh_token"],
                        "account_id": str((claims.get("https://api.openai.com/auth") or {}).get("chatgpt_account_id", "")),
                        "last_refresh": _t.strftime("%Y-%m-%dT%H:%M:%SZ", _t.gmtime(now)),
                        "email": claims.get("email", ""),
                        "type": "codex",
                        "plan": (claims.get("https://api.openai.com/auth") or {}).get("chatgpt_plan_type", ""),
                        "expired": _t.strftime("%Y-%m-%dT%H:%M:%SZ", _t.gmtime(now + token_data.get("expires_in", 0))),
                    }
                    broadcast_log(f"[extract] token extracted: {token_obj['email']} ({token_obj['plan']})")
                    return jsonify({"ok": True, "token": token_obj})
                resp = session.get(next_url, allow_redirects=False, timeout=15)

            return jsonify({"ok": False, "message": "oauth callback not found"})

        return jsonify({"ok": False, "message": "invalid step"})

    except Exception as e:
        broadcast_log(f"[extract] error: {e}")
        return jsonify({"ok": False, "message": str(e)})


@app.route("/api/add-channel", methods=["POST"])
@require_auth
def api_add_channel():
    body = request.get_json(silent=True) or {}
    token_obj = body.get("token", {})
    access_token = token_obj.get("access_token", "") if isinstance(token_obj, dict) else ""
    email = token_obj.get("email", "") if isinstance(token_obj, dict) else body.get("email", "")
    plan = token_obj.get("plan", "free") if isinstance(token_obj, dict) else body.get("plan", "free")
    def _models_for_plan(p):
        if "team" in str(p).lower():
            return "gpt-5.3,gpt-5.3-codex,gpt-5.3-codex-spark,gpt-5.4"
        return "gpt-5,gpt-5-codex,gpt-5-codex-mini,gpt-5.1,gpt-5.1-codex,gpt-5.1-codex-max,gpt-5.1-codex-mini,gpt-5.2,gpt-5.2-codex"

    models = body.get("models", _models_for_plan(plan))

    if not access_token and not token_obj:
        return jsonify({"ok": False, "message": "missing token data"})

    channel_key = json.dumps(token_obj, ensure_ascii=False, separators=(",", ":"))
    channel_name = f"ChatGPT-{str(plan).title()}-{(email.split('@')[0] if '@' in email else email) or 'account'}"

    try:
        conn = _get_db()
        with conn.cursor() as cur:
            # check if channel with same email already exists
            if email:
                cur.execute(
                    "SELECT id FROM channels WHERE type = 57 AND `key` LIKE %s LIMIT 1",
                    (f'%"email":"{email}"%',),
                )
                existing = cur.fetchone()
            else:
                existing = None

            if existing:
                cur.execute(
                    "UPDATE channels SET `key` = %s, name = %s, models = %s, status = 1 WHERE id = %s",
                    (channel_key, channel_name, models, existing["id"]),
                )
                conn.commit()
                conn.close()
                broadcast_log(f"[channel] updated #{existing['id']} {channel_name} ({plan})")
                return jsonify({"ok": True, "message": f"channel #{existing['id']} {channel_name} updated"})
            else:
                cur.execute(
                    "INSERT INTO channels (type, name, `key`, models, `group`, base_url, status, created_time, weight, auto_ban, priority, param_override, status_code_mapping) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, UNIX_TIMESTAMP(), %s, %s, %s, %s, %s)",
                    (57, channel_name, channel_key, models, "default,svip,codex", "http://codex-proxy:9006", 1, 1, 1, 0, '{"stream":true}', '{"400":"retry","429":"retry","502":"retry"}'),
                )
                conn.commit()
                conn.close()
                broadcast_log(f"[channel] added {channel_name} ({plan})")
                return jsonify({"ok": True, "message": f"channel {channel_name} added to new-api"})
    except Exception as e:
        return jsonify({"ok": False, "message": str(e)})


@app.route("/api/channels")
@require_auth
def api_channels():
    return jsonify(_build_monitor_payload()["channels"])


@app.route("/api/test-channel", methods=["POST"])
@require_auth
def api_test_channel():
    body = request.get_json(silent=True) or {}
    access_token = body.get("access_token", "")
    account_id = body.get("account_id", "")
    channel_id = body.get("channel_id")

    if channel_id and not access_token:
        try:
            conn = _get_db()
            with conn.cursor() as cur:
                cur.execute("SELECT `key` FROM channels WHERE id=%s AND type=57", (channel_id,))
                row = cur.fetchone()
            conn.close()
            if row:
                token_data = _decode_channel_key(row.get("key"))
                access_token = token_data.get("access_token", "")
                account_id = token_data.get("account_id", "")
        except Exception as e:
            return jsonify({"ok": False, "message": f"failed to load channel: {e}"})

    if not access_token:
        return jsonify({"ok": False, "message": "missing access_token"})

    try:
        from curl_cffi import requests as cffi_req

        headers = {
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
            "chatgpt-account-id": account_id,
            "OpenAI-Beta": "responses=experimental",
            "originator": "codex_cli_rs",
        }
        data = json.dumps(
            {
                "model": "gpt-5-codex",
                "input": [{"role": "user", "content": "say hi in one word"}],
                "instructions": "",
                "stream": True,
                "store": False,
            }
        )
        resp = cffi_req.post(
            "https://chatgpt.com/backend-api/codex/responses",
            headers=headers,
            data=data,
            impersonate="chrome",
            timeout=30,
        )
        if resp.status_code != 200:
            return jsonify({"ok": False, "message": f"{resp.status_code}: {resp.text[:200]}"})

        reply = ""
        for line in resp.text.split("\n"):
            if not line.startswith("data: "):
                continue
            try:
                event = json.loads(line[6:])
                if event.get("type") == "response.output_text.delta":
                    reply += event.get("delta", "")
            except Exception:
                pass
        broadcast_log(f"[test] channel test ok: {reply[:50]}")
        return jsonify({"ok": True, "reply": reply[:100]})
    except Exception as e:
        return jsonify({"ok": False, "message": str(e)})


@app.route("/api/delete-channel", methods=["POST"])
@require_auth
def api_delete_channel():
    body = request.get_json(silent=True) or {}
    channel_id = body.get("channel_id")
    if not channel_id:
        return jsonify({"ok": False, "message": "missing channel_id"})

    try:
        conn = _get_db()
        with conn.cursor() as cur:
            cur.execute("DELETE FROM channels WHERE id=%s AND type=57", (channel_id,))
            conn.commit()
        conn.close()
        broadcast_log(f"[channel] deleted #{channel_id}")
        return jsonify({"ok": True, "message": f"channel #{channel_id} deleted"})
    except Exception as e:
        return jsonify({"ok": False, "message": str(e)})


@app.route("/api/check-channels", methods=["POST"])
@require_auth
def api_check_channels():
    """Health check: test enabled Codex channels."""
    body = request.get_json(silent=True) or {}
    only_ids = body.get("ids") or []
    limit = int(body.get("limit") or 0)
    fast = body.get("fast", None)
    workers = body.get("workers", None)

    if isinstance(only_ids, (str, int)):
        only_ids = [only_ids]
    if isinstance(fast, str):
        fast = fast.lower() in ("1", "true", "yes")
    if isinstance(workers, str):
        try:
            workers = int(workers)
        except Exception:
            workers = None

    def _run_check():
        result = _check_channels_health(
            only_ids=only_ids,
            limit=limit,
            fast=fast,
            workers=workers,
        )
        broadcast_log(f"[health] check done: {json.dumps(result, ensure_ascii=False)}")
    threading.Thread(target=_run_check, daemon=True).start()
    return jsonify({"ok": True, "message": "health check started"})


def _check_channels_health(only_ids=None, limit=0, fast=None, workers=None):
    """Test status=1 type=57 channels against chatgpt.com."""
    from curl_cffi import requests as cffi_req

    summary = {
        "ok": 0,
        "deactivated": 0,
        "refreshed": 0,
        "disabled": 0,
        "usage_limit": 0,
        "reactivated": 0,
        "errors": 0,
    }
    try:
        conn = _get_db()
        with conn.cursor() as cur:
            cur.execute("SELECT id, name, `key`, status FROM channels WHERE type = 57 AND status IN (1, 3)")
            rows = cur.fetchall() or []
        conn.close()
    except Exception as e:
        broadcast_log(f"[health] db error: {e}")
        return summary

    if only_ids:
        id_set = {str(x) for x in only_ids}
        rows = [row for row in rows if str(row.get("id")) in id_set]

    if limit and limit > 0:
        rows = rows[:limit]

    if not rows:
        return summary

    if fast is None:
        fast = HEALTH_CHECK_FAST
    if workers is None:
        workers = HEALTH_CHECK_WORKERS
    try:
        workers = int(workers)
    except Exception:
        workers = HEALTH_CHECK_WORKERS
    if workers < 1:
        workers = 1

    timeout = HEALTH_CHECK_TIMEOUT_FAST if fast else HEALTH_CHECK_TIMEOUT
    summary_lock = threading.Lock()

    def bump(key, value=1):
        with summary_lock:
            summary[key] += value

    def check_row(row):
        ch_id = row["id"]
        ch_name = row.get("name", f"#{ch_id}")
        token_data = _decode_channel_key(row.get("key"))
        access_token = token_data.get("access_token", "")
        refresh_token = token_data.get("refresh_token", "")
        account_id = token_data.get("account_id", "")
        email = token_data.get("email", "")

        if not access_token:
            return

        try:
            headers = {
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
                "chatgpt-account-id": account_id,
                "OpenAI-Beta": "responses=experimental",
                "originator": "codex_cli_rs",
            }
            payload = {
                "model": "gpt-5-codex",
                "input": [{"role": "user", "content": "say hi"}],
                "instructions": "",
                "stream": not fast,
                "store": False,
            }
            if fast:
                payload["max_output_tokens"] = 1
            resp = cffi_req.post(
                "https://chatgpt.com/backend-api/codex/responses",
                headers=headers,
                data=json.dumps(payload),
                impersonate="chrome",
                timeout=timeout,
            )

            resp_text = resp.text[:500]

            if int(row.get("status", 1)) == 3:
                if resp.status_code == 200 and "usage limit" not in resp_text.lower():
                    _update_channel_status(ch_id, 1)
                    broadcast_log(f"[health] {ch_name} recovered, re-enabled")
                    bump("reactivated")
                else:
                    broadcast_log(f"[health] {ch_name} still limited (status={resp.status_code})")
                return

            if resp.status_code == 200:
                if "usage limit" in resp_text.lower():
                    _update_channel_status(ch_id, 3)
                    broadcast_log(f"[health] {ch_name} usage limit, temporarily disabled")
                    bump("usage_limit")
                else:
                    bump("ok")
                return

            if resp.status_code == 401:
                if "deactivated" in resp_text.lower():
                    _delete_channel_and_auth(ch_id, email)
                    broadcast_log(f"[health] {ch_name} deactivated, removed")
                    bump("deactivated")
                elif "invalid" in resp_text.lower() or "expired" in resp_text.lower():
                    if refresh_token:
                        try:
                            new_tokens = _refresh_access_token(refresh_token)
                            token_data["access_token"] = new_tokens.get("access_token", "")
                            if new_tokens.get("refresh_token"):
                                token_data["refresh_token"] = new_tokens["refresh_token"]
                            if new_tokens.get("id_token"):
                                token_data["id_token"] = new_tokens["id_token"]
                            token_data["last_refresh"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                            token_data["expired"] = time.strftime(
                                "%Y-%m-%dT%H:%M:%SZ",
                                time.gmtime(time.time() + new_tokens.get("expires_in", 3600)),
                            )
                            new_key = json.dumps(token_data, ensure_ascii=False, separators=(",", ":"))
                            conn2 = _get_db()
                            with conn2.cursor() as cur2:
                                cur2.execute("UPDATE channels SET `key` = %s WHERE id = %s", (new_key, ch_id))
                                conn2.commit()
                            conn2.close()
                            broadcast_log(f"[health] {ch_name} token refreshed")
                            bump("refreshed")
                        except Exception as re:
                            _update_channel_status(ch_id, 2)
                            broadcast_log(f"[health] {ch_name} refresh failed ({re}), disabled")
                            bump("disabled")
                    else:
                        _update_channel_status(ch_id, 2)
                        broadcast_log(f"[health] {ch_name} missing refresh_token, disabled")
                        bump("disabled")
                else:
                    _update_channel_status(ch_id, 2)
                    broadcast_log(f"[health] {ch_name} 401 unknown: {resp_text[:100]}")
                    bump("disabled")
                return

            if "usage limit" in resp_text.lower():
                _update_channel_status(ch_id, 3)
                broadcast_log(f"[health] {ch_name} usage limit (status={resp.status_code}), temporarily disabled")
                bump("usage_limit")
            else:
                broadcast_log(f"[health] {ch_name} status={resp.status_code}: {resp_text[:100]}")
                bump("errors")

        except Exception as e:
            broadcast_log(f"[health] {ch_name} request error: {e}")
            bump("errors")

    if workers == 1 or len(rows) == 1:
        for row in rows:
            check_row(row)
        return summary

    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(check_row, rows))

    return summary


def _update_channel_status(channel_id, status):
    """Update channel status."""
    try:
        conn = _get_db()
        with conn.cursor() as cur:
            cur.execute("UPDATE channels SET status = %s WHERE id = %s", (status, channel_id))
            conn.commit()
        conn.close()
    except Exception as e:
        broadcast_log(f"[health] 更新渠道 #{channel_id} 状态失? {e}")


def _delete_channel_and_auth(channel_id, email):
    """Delete channel record and corresponding auth file."""
    try:
        conn = _get_db()
        with conn.cursor() as cur:
            cur.execute("DELETE FROM channels WHERE id = %s AND type = 57", (channel_id,))
            conn.commit()
        conn.close()
    except Exception as e:
        broadcast_log(f"[health] 鍒犻櫎娓犻亾 #{channel_id} 澶辫? {e}")

    if email:
        for pattern in [f"codex-{email}.json", f"codex-{email.lower()}.json"]:
            path = os.path.join(AUTH_DIR, pattern)
            if os.path.exists(path):
                try:
                    os.remove(path)
                    broadcast_log(f"[health] 已删?auth 文件: {pattern}")
                except Exception as e:
                    broadcast_log(f"[health] 鍒犻?auth 鏂囦欢澶辫触: {e}")


@app.route("/api/set-channel-proxy", methods=["POST"])
@require_auth
def api_set_channel_proxy():
    body = request.get_json(silent=True) or {}
    channel_ids = body.get("channel_ids", [])
    proxy = body.get("proxy", "")
    if not channel_ids:
        return jsonify({"ok": False, "message": "missing channel_ids"})

    try:
        conn = _get_db()
        updated = 0
        with conn.cursor() as cur:
            for cid in channel_ids:
                cur.execute(
                    "SELECT setting FROM channels WHERE id=%s AND type=57", (cid,)
                )
                row = cur.fetchone()
                if not row:
                    continue
                setting = json.loads(row.get("setting") or "{}") if row.get("setting") else {}
                setting["proxy"] = proxy
                cur.execute(
                    "UPDATE channels SET setting=%s WHERE id=%s",
                    (json.dumps(setting, ensure_ascii=False), cid),
                )
                updated += 1
        conn.commit()
        conn.close()
        broadcast_log(f"[channel] set proxy for {updated} channels: {proxy or '(cleared)'}")
        return jsonify({"ok": True, "message": f"updated {updated} channels"})
    except Exception as e:
        return jsonify({"ok": False, "message": str(e)})


@app.route("/api/batch-update-channels", methods=["POST"])
@require_auth
def api_batch_update_channels():
    body = request.get_json(silent=True) or {}
    channel_ids = body.get("channel_ids", [])
    models = body.get("models")
    group = body.get("group")
    add_models = body.get("add_models")
    remove_models = body.get("remove_models")
    if not channel_ids:
        return jsonify({"ok": False, "message": "missing channel_ids"})
    if models is None and group is None and add_models is None and remove_models is None:
        return jsonify({"ok": False, "message": "missing models, add_models, remove_models, or group"})

    try:
        conn = _get_db()
        updated = 0

        # add_models / remove_models need per-row read-modify-write
        if add_models is not None or remove_models is not None:
            add_set = set(m.strip() for m in (add_models or "").split(",") if m.strip())
            rm_set = set(m.strip() for m in (remove_models or "").split(",") if m.strip())
            with conn.cursor() as cur:
                placeholders = ",".join(["%s"] * len(channel_ids))
                cur.execute(
                    f"SELECT id, models FROM channels WHERE type = 57 AND id IN ({placeholders})",
                    channel_ids,
                )
                rows = cur.fetchall() or []
                for row in rows:
                    existing = [m.strip() for m in (row.get("models") or "").split(",") if m.strip()]
                    existing_set = set(existing)
                    # preserve order, add new ones at end
                    if add_set:
                        for m in add_set:
                            if m not in existing_set:
                                existing.append(m)
                    if rm_set:
                        existing = [m for m in existing if m not in rm_set]
                    new_models = ",".join(existing)
                    cur.execute(
                        "UPDATE channels SET models = %s WHERE id = %s",
                        (new_models, row["id"]),
                    )
                    updated += 1
            conn.commit()
            conn.close()
            parts = []
            if add_set:
                parts.append(f"added={','.join(add_set)}")
            if rm_set:
                parts.append(f"removed={','.join(rm_set)}")
            broadcast_log(f"[channel] batch updated {updated} channels: {', '.join(parts)}")
            return jsonify({"ok": True, "message": f"updated {updated} channels"})

        # models (overwrite) / group: bulk UPDATE
        with conn.cursor() as cur:
            placeholders = ",".join(["%s"] * len(channel_ids))
            sets = []
            params = []
            if models is not None:
                sets.append("models = %s")
                params.append(models)
            if group is not None:
                sets.append("`group` = %s")
                params.append(group)
            params.extend(channel_ids)
            cur.execute(
                f"UPDATE channels SET {', '.join(sets)} WHERE type = 57 AND id IN ({placeholders})",
                params,
            )
            updated = cur.rowcount
        conn.commit()
        conn.close()
        parts = []
        if models is not None:
            parts.append(f"models={models}")
        if group is not None:
            parts.append(f"group={group}")
        broadcast_log(f"[channel] batch updated {updated} channels: {', '.join(parts)}")
        return jsonify({"ok": True, "message": f"updated {updated} channels"})
    except Exception as e:
        return jsonify({"ok": False, "message": str(e)})


@sock.route("/ws/logs")
def ws_logs(ws):
    if DASHBOARD_PWD:
        try:
            msg = ws.receive(timeout=5)
            data = json.loads(msg)
            if data.get("token") != DASHBOARD_PWD:
                ws.send(json.dumps({"type": "error", "data": "auth failed"}))
                return
        except Exception:
            return

    with log_lock:
        for line in log_buffer:
            ws.send(json.dumps({"type": "log", "data": line}))

    ws.send(json.dumps({"type": "status", "data": _build_status()}))

    with ws_lock:
        ws_clients.add(ws)
    try:
        while True:
            ws.receive(timeout=30)
    except Exception:
        pass
    finally:
        with ws_lock:
            ws_clients.discard(ws)


# ============================================================
# Token auto-refresh thread
# Check all Codex channel access_token expiry every 30 min
# Auto refresh with refresh_token 10 min before expiry
# ============================================================

TOKEN_REFRESH_INTERVAL = 30 * 60
TOKEN_REFRESH_MARGIN = 10 * 60
TOKEN_ENDPOINT = "https://auth.openai.com/oauth/token"
TOKEN_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
HEALTH_CHECK_INTERVAL = int(os.environ.get("HEALTH_CHECK_INTERVAL", "60"))
HEALTH_CHECK_WORKERS = int(os.environ.get("HEALTH_CHECK_WORKERS", "4"))
HEALTH_CHECK_TIMEOUT = int(os.environ.get("HEALTH_CHECK_TIMEOUT", "30"))
HEALTH_CHECK_TIMEOUT_FAST = int(os.environ.get("HEALTH_CHECK_TIMEOUT_FAST", "10"))
HEALTH_CHECK_FAST = os.environ.get("HEALTH_CHECK_FAST", "0").lower() in ("1", "true", "yes")


def _refresh_access_token(refresh_token: str) -> dict:
    """Exchange refresh_token for new access_token."""
    form = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "client_id": TOKEN_CLIENT_ID,
        "refresh_token": refresh_token,
    }).encode()
    req = urllib.request.Request(
        TOKEN_ENDPOINT,
        data=form,
        method="POST",
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def _token_refresh_loop():
    """Background loop: scan all Codex channels, auto-refresh expiring tokens."""
    broadcast_log("[token-refresh] background thread started")
    while True:
        try:
            time.sleep(TOKEN_REFRESH_INTERVAL)
            conn = _get_db()
            with conn.cursor() as cur:
                cur.execute("SELECT id, name, `key` FROM channels WHERE type = 57 AND status = 1")
                rows = cur.fetchall() or []
            conn.close()

            now = time.time()
            refreshed = 0
            for row in rows:
                token_data = _decode_channel_key(row.get("key"))
                refresh_token = token_data.get("refresh_token", "") if token_data else ""
                if not refresh_token:
                    continue

                expired_str = token_data.get("expired", "")
                if expired_str:
                    try:
                        exp_ts = time.mktime(time.strptime(expired_str, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
                    except Exception:
                        exp_ts = 0
                else:
                    claims = _decode_jwt_payload(token_data.get("access_token", ""))
                    exp_ts = claims.get("exp", 0)

                if exp_ts and (exp_ts - now) > TOKEN_REFRESH_MARGIN:
                    continue

                ch_name = row.get("name", f"#{row.get('id')}")
                try:
                    new_tokens = _refresh_access_token(refresh_token)
                    token_data["access_token"] = new_tokens["access_token"]
                    if new_tokens.get("refresh_token"):
                        token_data["refresh_token"] = new_tokens["refresh_token"]
                    if new_tokens.get("id_token"):
                        token_data["id_token"] = new_tokens["id_token"]
                    token_data["last_refresh"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                    token_data["expired"] = time.strftime(
                        "%Y-%m-%dT%H:%M:%SZ",
                        time.gmtime(time.time() + new_tokens.get("expires_in", 3600)),
                    )
                    new_key = json.dumps(token_data, ensure_ascii=False, separators=(",", ":"))
                    conn2 = _get_db()
                    with conn2.cursor() as cur2:
                        cur2.execute("UPDATE channels SET `key` = %s WHERE id = %s", (new_key, row["id"]))
                        conn2.commit()
                    conn2.close()
                    refreshed += 1
                    broadcast_log(f"[token-refresh] {ch_name} token refreshed")
                except Exception as e:
                    broadcast_log(f"[token-refresh] {ch_name} refresh failed: {e}")

            if refreshed:
                broadcast_log(f"[token-refresh] cycle complete: refreshed={refreshed}")

            try:
                broadcast_log("[token-refresh] running health check after refresh cycle")
                health_result = _check_channels_health(fast=True)
                broadcast_log(f"[token-refresh] health check done: {json.dumps(health_result, ensure_ascii=False)}")
            except Exception as he:
                broadcast_log(f"[token-refresh] health check error: {he}")
        except Exception as e:
            broadcast_log(f"[token-refresh] loop error: {e}")


def _health_check_loop():
    """Standalone health check loop, runs every HEALTH_CHECK_INTERVAL seconds."""
    broadcast_log(f"[health] background health check thread started (interval={HEALTH_CHECK_INTERVAL}s)")
    while True:
        try:
            time.sleep(HEALTH_CHECK_INTERVAL)
            result = _check_channels_health(fast=True)
            if any(result.values()):
                broadcast_log(f"[health] auto-check: {json.dumps(result, ensure_ascii=False)}")
        except Exception as e:
            broadcast_log(f"[health] auto-check error: {e}")


if __name__ == "__main__":
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    os.makedirs(AUTH_DIR, exist_ok=True)
    threading.Thread(target=_token_refresh_loop, daemon=True).start()
    threading.Thread(target=_health_check_loop, daemon=True).start()
    print("[dashboard] starting unified dashboard on :9005")
    print(f"[dashboard] password protected: {'yes' if DASHBOARD_PWD else 'no'}")
    app.run(host="0.0.0.0", port=9005, debug=False)
