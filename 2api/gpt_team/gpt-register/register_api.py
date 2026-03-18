import json
import os
import re
import sys
import time
import uuid
import math
import random
import string
import secrets
import hashlib
import base64
import threading
from datetime import datetime, timezone, timedelta
from urllib import request as urllib_request
from urllib.parse import urlparse, parse_qs, urlencode, quote
from dataclasses import dataclass
from typing import Any, Dict
import urllib
from urllib.parse import urlparse, parse_qs
from urllib import request

from curl_cffi import requests

# email
def get(url: str, headers: dict | None=None) -> tuple[str, dict]:
    try:
        req = urllib.request.Request(url, headers = headers or {})
        with urllib.request.urlopen(req) as response:
            resp_text = response.read().decode("utf-8")
            resp_headers = dict(response.getheaders())
            return resp_text, resp_headers
    except Exception as e:
            print(e)
            return -1, {}

def get_email() -> str:
    body, _ = get("https://mail.chatgpt.org.uk/api/generate-email", {"X-API-Key": "gpt-test", "User-Agent": "Mozilla/5.0"})
    if body == -1:
        raise RuntimeError("邮箱 API 请求失败")
    data = json.loads(body)
    return data["data"]["email"]

def get_oai_code(email: str) -> str:
    regex = r" (?<!\d)(\d{6})(?!\d)"
    for i in range(20):
        body,_ = get(f"https://mail.chatgpt.org.uk/api/emails?email={email}", {"referer": "https://mail.chatgpt.org.uk/", "User-Agent": "Mozilla/5.0"})
        if body == -1:
            time.sleep(3)
            continue
        data = json.loads(body)
        emails = data["data"]["emails"]
        for em in emails:
            if "openai" in em["from_address"]:
                m = re.search(regex, em["subject"])
                if m:
                    return m.group(1)
                m = re.search(regex, em["html_content"])
                if m:
                    return m.group(1)
        time.sleep(3)
    raise RuntimeError("验证码获取超时")


# oauth
AUTH_URL = "https://auth.openai.com/oauth/authorize"
TOKEN_URL = "https://auth.openai.com/oauth/token"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"

DEFAULT_REDIRECT_URI = f"http://localhost:1455/auth/callback"
DEFAULT_SCOPE = "openid email profile offline_access"

def _b64url_no_pad(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

def _sha256_b64url_no_pad(s: str) -> str:
    return _b64url_no_pad(hashlib.sha256(s.encode("ascii")).digest())

def _random_state(nbytes: int = 16) -> str:
    return secrets.token_urlsafe(nbytes)

def _pkce_verifier() -> str:
    return secrets.token_urlsafe(64)

def _parse_callback_url(callback_url: str) -> Dict[str, str]:
    candidate = callback_url.strip()
    if not candidate:
        return {"code": "", "state": "", "error": "", "error_description": ""}
    if "://" not in candidate:
        if candidate.startswith("?"):
            candidate = f"http://localhost{candidate}"
        elif any(ch in candidate for ch in "/?#") or ":" in candidate:
            candidate = f"http://{candidate}"
        elif "=" in candidate:
            candidate = f"http://localhost/?{candidate}"
    parsed = urllib.parse.urlparse(candidate)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    fragment = urllib.parse.parse_qs(parsed.fragment, keep_blank_values=True)
    for key, values in fragment.items():
        if key not in query or not query[key] or not (query[key][0] or "").strip():
            query[key] = values
    def get1(k: str) -> str:
        v = query.get(k, [""])
        return (v[0] or "").strip()
    code = get1("code")
    state = get1("state")
    error = get1("error")
    error_description = get1("error_description")
    if code and not state and "#" in code:
        code, state = code.split("#", 1)
    if not error and error_description:
        error, error_description = error_description, ""
    return {"code": code, "state": state, "error": error, "error_description": error_description}

def _jwt_claims_no_verify(id_token: str) -> Dict[str, Any]:
    if not id_token or id_token.count(".") < 2:
        return {}
    payload_b64 = id_token.split(".")[1]
    pad = "=" * ((4 - (len(payload_b64) % 4)) % 4)
    try:
        payload = base64.urlsafe_b64decode((payload_b64 + pad).encode("ascii"))
        return json.loads(payload.decode("utf-8"))
    except Exception:
        return {}

def _to_int(v: Any) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0

def _post_form(url: str, data: Dict[str, str], timeout: int = 30) -> Dict[str, Any]:
    body = urllib.parse.urlencode(data).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            if resp.status != 200:
                raise RuntimeError(f"token exchange failed: {resp.status}: {raw.decode('utf-8', 'replace')}")
            return json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        raise RuntimeError(f"token exchange failed: {exc.code}: {raw.decode('utf-8', 'replace')}") from exc


@dataclass(frozen=True)
class OAuthStart:
    auth_url: str
    state: str
    code_verifier: str
    redirect_uri: str


def generate_oauth_url(*, redirect_uri: str = DEFAULT_REDIRECT_URI, scope: str = DEFAULT_SCOPE) -> OAuthStart:
    state = _random_state()
    code_verifier = _pkce_verifier()
    code_challenge = _sha256_b64url_no_pad(code_verifier)
    params = {
        "client_id": CLIENT_ID, "response_type": "code", "redirect_uri": redirect_uri,
        "scope": scope, "state": state, "code_challenge": code_challenge,
        "code_challenge_method": "S256", "prompt": "login",
        "id_token_add_organizations": "true", "codex_cli_simplified_flow": "true",
    }
    auth_url = f"{AUTH_URL}?{urllib.parse.urlencode(params)}"
    return OAuthStart(auth_url=auth_url, state=state, code_verifier=code_verifier, redirect_uri=redirect_uri)


def submit_callback_url(*, callback_url: str, expected_state: str, code_verifier: str, redirect_uri: str = DEFAULT_REDIRECT_URI) -> str:
    cb = _parse_callback_url(callback_url)
    if cb["error"]:
        desc = cb["error_description"]
        raise RuntimeError(f"oauth error: {cb['error']}: {desc}".strip())
    if not cb["code"]:
        raise ValueError("callback url missing ?code=")
    if not cb["state"]:
        raise ValueError("callback url missing ?state=")
    if cb["state"] != expected_state:
        raise ValueError("state mismatch")
    token_resp = _post_form(TOKEN_URL, {
        "grant_type": "authorization_code", "client_id": CLIENT_ID,
        "code": cb["code"], "redirect_uri": redirect_uri, "code_verifier": code_verifier,
    })
    access_token = (token_resp.get("access_token") or "").strip()
    refresh_token = (token_resp.get("refresh_token") or "").strip()
    id_token = (token_resp.get("id_token") or "").strip()
    expires_in = _to_int(token_resp.get("expires_in"))
    claims = _jwt_claims_no_verify(id_token)
    email = str(claims.get("email") or "").strip()
    auth_claims = claims.get("https://api.openai.com/auth") or {}
    account_id = str(auth_claims.get("chatgpt_account_id") or "").strip()
    now = int(time.time())
    expired_rfc3339 = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + max(expires_in, 0)))
    now_rfc3339 = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    config = {
        "id_token": id_token, "access_token": access_token, "refresh_token": refresh_token,
        "account_id": account_id, "last_refresh": now_rfc3339, "email": email,
        "type": "codex", "expired": expired_rfc3339,
    }
    return json.dumps(config, ensure_ascii=False, separators=(",", ":"))


ALLOWED_REGIONS = {"US", "JP", "KR", "DE", "GB", "FR", "NL", "SE", "CA", "AU"}


def run(proxy: str) -> str:
    proxies = {"http": proxy, "https": proxy} if proxy else None
    s = requests.Session(proxies=proxies, impersonate="chrome")
    trace = s.get("https://cloudflare.com/cdn-cgi/trace", timeout=10)
    trace = trace.text
    ip_re = re.search(r"^ip=(.+)$", trace, re.MULTILINE)
    loc_re = re.search(r"^loc=(.+)$", trace, re.MULTILINE)
    ip = ip_re.group(1) if ip_re else None
    loc = loc_re.group(1) if loc_re else None
    print(f"[*] IP: {ip}, 地区: {loc}")
    if loc not in ALLOWED_REGIONS:
        print(f"[!] {loc} 不在允许地区内，跳过")
        return None
    email = get_email()
    print(f"[*] 邮箱: {email}")
    oauth = generate_oauth_url()
    url = oauth.auth_url
    resp = s.get(url)
    did = s.cookies.get("oai-did")
    print(f"[*] Device ID: {did}")
    signup_body = f'{{"username":{{"value":"{email}","kind":"email"}},"screen_hint":"signup"}}'
    sen_req_body = f'{{"p":"","id":"{did}","flow":"authorize_continue"}}'
    sen_resp = requests.post("https://sentinel.openai.com/backend-api/sentinel/req", headers={"origin": "https://sentinel.openai.com", "referer": "https://sentinel.openai.com/backend-api/sentinel/frame.html?sv=20260219f9f6", "content-type": "text/plain;charset=UTF-8"}, data=sen_req_body, proxies=proxies, impersonate="chrome")
    print(f"[*] Sentinel: {sen_resp.status_code}")
    if sen_resp.status_code != 200:
        print(f"[!] Sentinel 失败: {sen_resp.text}")
        return None
    sen_token = sen_resp.json()["token"]
    sentinel = f'{{"p": "", "t": "", "c": "{sen_token}", "id": "{did}", "flow": "authorize_continue"}}'
    signup_resp = s.post("https://auth.openai.com/api/accounts/authorize/continue", headers={"referer": "https://auth.openai.com/create-account", "accept": "application/json", "content-type": "application/json", "openai-sentinel-token": sentinel}, data=signup_body)
    print(f"[*] Signup: {signup_resp.status_code}")
    if signup_resp.status_code >= 400:
        print(f"[!] Signup 失败: {signup_resp.text}")
        return None
    otp_resp = s.post("https://auth.openai.com/api/accounts/passwordless/send-otp", headers={"referer": "https://auth.openai.com/create-account/password", "accept": "application/json", "content-type": "application/json"})
    print(f"[*] Send OTP: {otp_resp.status_code}")
    code = get_oai_code(email)
    print(f"[*] 验证码: {code}")
    code_body = f'{{"code":"{code}"}}'
    code_resp = s.post("https://auth.openai.com/api/accounts/email-otp/validate", headers={"referer": "https://auth.openai.com/email-verification", "accept": "application/json", "content-type": "application/json"}, data=code_body)
    print(f"[*] Validate OTP: {code_resp.status_code}")
    first_names = ["Alex", "Chris", "Jordan", "Taylor", "Morgan", "Sam", "Casey", "Riley", "Quinn", "Avery"]
    last_names = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Wilson", "Moore"]
    name = f"{random.choice(first_names)} {random.choice(last_names)}"
    year = random.randint(1980, 2002)
    month = random.randint(1, 12)
    day = random.randint(1, 28)
    birthdate = f"{year}-{month:02d}-{day:02d}"
    create_account_body = f'{{"name":"{name}","birthdate":"{birthdate}"}}'
    create_account_resp = s.post("https://auth.openai.com/api/accounts/create_account", headers={"referer": "https://auth.openai.com/about-you", "accept": "application/json", "content-type": "application/json"}, data=create_account_body)
    create_account_status = create_account_resp.status_code
    print(f"[*] Create Account: {create_account_status}")
    if create_account_status != 200:
        print(f"[!] 创建失败: {create_account_resp.text}")
        return None
    auth = s.cookies.get("oai-client-auth-session")
    auth = base64.b64decode(auth.split(".")[0])
    auth = json.loads(auth)
    workspace_id = auth["workspaces"][0]["id"]
    print(f"[*] Workspace: {workspace_id}")
    select_body = f'{{"workspace_id":"{workspace_id}"}}'
    select_resp = s.post("https://auth.openai.com/api/accounts/workspace/select", headers={"referer": "https://auth.openai.com/sign-in-with-chatgpt/codex/consent", "content-type": "application/json"}, data=select_body)
    print(f"[*] Select Workspace: {select_resp.status_code}")
    continue_url = select_resp.json()["continue_url"]
    final_resp = s.get(continue_url, allow_redirects=False)
    final_resp = s.get(final_resp.headers.get("Location"), allow_redirects=False)
    final_resp = s.get(final_resp.headers.get("Location"), allow_redirects=False)
    cbk = final_resp.headers.get("Location")
    return submit_callback_url(callback_url=cbk, code_verifier=oauth.code_verifier, redirect_uri=oauth.redirect_uri, expected_state=oauth.state)

if __name__ == "__main__":
    proxy = os.environ.get("PROXY_URL", "")
    max_retries = 10
    for attempt in range(1, max_retries + 1):
        print(f"\n===== 第 {attempt}/{max_retries} 次尝试 =====")
        try:
            result = run(proxy or None)
            if result:
                print(f"\n[OK] 注册成功!\n{result}")
                break
            else:
                print(f"[*] 重试中...")
                time.sleep(2)
        except Exception as e:
            print(f"[!] 错误: {e}")
            time.sleep(2)
    else:
        print("\n[FAIL] 达到最大重试次数")
