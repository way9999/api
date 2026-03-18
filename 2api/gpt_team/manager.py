import os
import sys
import time
import json
import re
import uuid
import random
import string
import secrets
import hashlib
import base64
import threading
import argparse
import urllib.parse
from datetime import datetime
from typing import Any, Dict, Optional
from dataclasses import dataclass

from curl_cffi import requests

# 注入模块（添加 new-api 渠道 + CLIProxyAPI auth）
try:
    # 容器内: /app/inject.py（通过 volume 挂载）
    # 本地开发: ./gpt-register/inject.py（相对于 manager.py）
    _inject_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gpt-register")
    if not os.path.isdir(_inject_dir):
        # 容器内 inject.py 直接在 /app/ 下
        _inject_dir = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, _inject_dir)
    from inject import inject_token, add_channel_to_newapi
except ImportError:
    inject_token = None
    add_channel_to_newapi = None

OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/app/output")

# Mail.tm API 配置（免费临时邮箱，无需 API key）
MAILTM_BASE = "https://api.mail.tm"


def _mailtm_headers(*, token: str = "", use_json: bool = False) -> dict:
    headers = {"Accept": "application/json"}
    if use_json:
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def mailtm_create_mailbox(proxies=None) -> Optional[tuple]:
    """通过 Mail.tm 创建临时邮箱，返回 (email, token, password) 或 None"""
    try:
        # 获取可用域名
        resp = requests.get(
            f"{MAILTM_BASE}/domains",
            headers=_mailtm_headers(),
            proxies=proxies,
            impersonate="chrome",
            timeout=15,
        )
        data = resp.json()
        items = data if isinstance(data, list) else (data.get("hydra:member") or data.get("items") or [])
        domains = [
            d["domain"] for d in items
            if isinstance(d, dict) and d.get("domain") and d.get("isActive", True) and not d.get("isPrivate", False)
        ]
        if not domains:
            print("[!] Mail.tm 没有可用域名")
            return None

        # 创建邮箱（最多重试 5 次）
        for _ in range(5):
            local = f"oc{secrets.token_hex(5)}"
            domain = random.choice(domains)
            email = f"{local}@{domain}"
            password = secrets.token_urlsafe(18)

            create_resp = requests.post(
                f"{MAILTM_BASE}/accounts",
                headers=_mailtm_headers(use_json=True),
                json={"address": email, "password": password},
                proxies=proxies,
                impersonate="chrome",
                timeout=15,
            )
            if create_resp.status_code not in (200, 201):
                continue

            token_resp = requests.post(
                f"{MAILTM_BASE}/token",
                headers=_mailtm_headers(use_json=True),
                json={"address": email, "password": password},
                proxies=proxies,
                impersonate="chrome",
                timeout=15,
            )
            if token_resp.status_code == 200:
                token = (token_resp.json().get("token") or "").strip()
                if token:
                    return (email, token, password)

        print("[!] Mail.tm 邮箱创建失败")
        return None
    except Exception as e:
        print(f"[!] Mail.tm 出错: {e}")
        return None


def mailtm_wait_otp(mail_token: str, timeout: int = 150, interval: int = 3, proxies=None) -> Optional[str]:
    """轮询 Mail.tm 收件箱，提取 OpenAI 6 位验证码"""
    deadline = time.time() + timeout
    seen_ids = set()
    while time.time() < deadline:
        try:
            resp = requests.get(
                f"{MAILTM_BASE}/messages",
                headers=_mailtm_headers(token=mail_token),
                proxies=proxies,
                impersonate="chrome",
                timeout=15,
            )
            if resp.status_code != 200:
                time.sleep(interval)
                continue

            data = resp.json()
            messages = data if isinstance(data, list) else (data.get("hydra:member") or [])

            for msg in messages:
                msg_id = msg.get("id") or msg.get("@id", "")
                if msg_id in seen_ids:
                    continue
                seen_ids.add(msg_id)

                # 获取完整邮件
                detail_resp = requests.get(
                    f"{MAILTM_BASE}/messages/{msg_id.split('/')[-1]}",
                    headers=_mailtm_headers(token=mail_token),
                    proxies=proxies,
                    impersonate="chrome",
                    timeout=15,
                )
                if detail_resp.status_code != 200:
                    continue

                detail = detail_resp.json()
                sender = str(detail.get("from", {}).get("address", "")).lower()
                subject = str(detail.get("subject", "")).lower()
                if "openai" not in sender and "openai" not in subject:
                    continue

                text = " ".join([
                    str(detail.get("subject", "")),
                    str(detail.get("intro", "")),
                    str(detail.get("text", "")),
                    re.sub(r"<[^>]+>", " ", str(detail.get("html", "") or "")),
                ])
                codes = re.findall(r"(?<!\d)(\d{6})(?!\d)", text)
                if codes:
                    return codes[-1]
        except Exception as e:
            print(f"[!] Mail.tm 轮询出错: {e}")
        time.sleep(interval)
    return None


CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
AUTH_URL = "https://auth.openai.com/oauth/authorize"
TOKEN_URL = "https://auth.openai.com/oauth/token"
DEFAULT_REDIRECT_URI = "http://localhost:1455/auth/callback"
DEFAULT_SCOPE = "openid email profile offline_access"


@dataclass(frozen=True)
class OAuthStart:
    auth_url: str
    state: str
    code_verifier: str
    redirect_uri: str


def _b64url_no_pad(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _sha256_b64url_no_pad(s: str) -> str:
    return _b64url_no_pad(hashlib.sha256(s.encode("ascii")).digest())


def _random_state(nbytes: int = 16) -> str:
    return secrets.token_urlsafe(nbytes)


def _pkce_verifier() -> str:
    return secrets.token_urlsafe(64)


def _generate_password(length: int = 12) -> str:
    chars = string.ascii_letters + string.digits
    return "".join(secrets.choice(chars) for _ in range(length))


def _jwt_claims_no_verify(id_token: str) -> Dict[str, Any]:
    if not id_token or id_token.count(".") < 2:
        return {}
    payload_b64 = id_token.split(".")[1]
    pad = "=" * ((4 - (len(payload_b64) % 4)) % 4)
    try:
        payload = base64.urlsafe_b64decode((payload_b64 + pad).encode("ascii"))
        return json.loads(payload.decode("utf-8"))
    except:
        return {}


def _decode_jwt_segment(seg: str) -> Dict[str, Any]:
    raw = (seg or "").strip()
    if not raw:
        return {}
    pad = "=" * ((4 - (len(raw) % 4)) % 4)
    try:
        decoded = base64.urlsafe_b64decode((raw + pad).encode("ascii"))
        return json.loads(decoded.decode("utf-8"))
    except:
        return {}


def _parse_callback_url(callback_url: str) -> Dict[str, str]:
    parsed = urllib.parse.urlparse(callback_url)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    fragment = urllib.parse.parse_qs(parsed.fragment, keep_blank_values=True)
    for k, v in fragment.items():
        if k not in query:
            query[k] = v
    return {
        "code": (query.get("code", [""])[0] or "").strip(),
        "state": (query.get("state", [""])[0] or "").strip(),
        "error": (query.get("error", [""])[0] or "").strip(),
        "error_description": (query.get("error_description", [""])[0] or "").strip(),
    }


class ChatGPTManager:
    def __init__(self, args):
        self.base_url = args.base_url.rstrip("/")
        self.mgmt_key = args.mgmt_key
        self.target = args.target
        self.check_interval = args.check_interval
        self.reg_delay_min = args.reg_delay_min
        self.reg_delay_max = args.reg_delay_max
        self.proxy = args.proxy

        self.current_reg_delay = random.randint(self.reg_delay_min, self.reg_delay_max)
        self.headers = {
            "Authorization": f"Bearer {self.mgmt_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def log(self, msg):
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{timestamp}] {msg}")

    def get_remote_accounts(self):
        try:
            url = f"{self.base_url}/v0/management/auth-files"
            resp = requests.get(
                url, headers=self.headers, impersonate="chrome", timeout=20
            )
            if resp.status_code == 200:
                return resp.json().get("files", [])
            return []
        except Exception as e:
            self.log(f"[!] 获取账号列表出错: {e}")
            return []

    def delete_remote_account(self, name):
        try:
            url = f"{self.base_url}/v0/management/auth-files"
            resp = requests.delete(
                url, headers=self.headers, params={"name": name}, impersonate="chrome"
            )
            return resp.status_code in (200, 204)
        except:
            return False

    def check_and_cleanup(self):
        self.log("[*] 开始执行账号健康状态扫描...")
        accounts = self.get_remote_accounts()
        if not accounts:
            return 0

        invalid_count = 0
        for acc in accounts:
            email = acc.get("email")
            auth_index = acc.get("auth_index")
            filename = acc.get("name")
            account_id = acc.get("id_token", {}).get("chatgpt_account_id")

            if not auth_index:
                continue

            payload = {
                "authIndex": auth_index,
                "method": "GET",
                "url": "https://chatgpt.com/backend-api/wham/usage",
                "header": {
                    "Authorization": "Bearer $TOKEN$",
                    "Content-Type": "application/json",
                    "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal",
                    "Chatgpt-Account-Id": account_id if account_id else "",
                },
            }
            try:
                resp = requests.post(
                    f"{self.base_url}/v0/management/api-call",
                    headers=self.headers,
                    json=payload,
                    impersonate="chrome",
                    timeout=15,
                )
                data = resp.json()
                status = data.get("status_code")
                if not status and "body" in data:
                    try:
                        status = json.loads(data["body"]).get("status")
                    except:
                        pass

                if status == 401:
                    self.log(f"  [-] 账号 {email} 已失效 (401)，正在删除...")
                    if self.delete_remote_account(filename):
                        invalid_count += 1
            except:
                pass

        self.log(f"[+] 扫描完成，共清理 {invalid_count} 个失效账号。")
        return len(accounts) - invalid_count

    def upload_token_data(self, token_json):
        try:
            data = json.loads(token_json)
            email = data.get("email", "unknown")
            filename = f"token_{email.replace('@', '_')}_{int(time.time())}.json"

            url = f"{self.base_url}/v0/management/auth-files?name={filename}"

            resp = requests.post(
                url,
                headers={
                    "Authorization": f"Bearer {self.mgmt_key}",
                    "Content-Type": "application/json",
                },
                data=token_json,
                impersonate="chrome",
            )
            return resp.status_code == 200
        except Exception as e:
            self.log(f"[!] 上传 Token 失败: {e}")
            return False

    def register_one(self):
        proxies = {"http": self.proxy, "https": self.proxy} if self.proxy else None
        s = requests.Session(proxies=proxies, impersonate="chrome")

        email = None
        mail_token = None
        try:
            # 1. 通过 Mail.tm 创建临时邮箱
            result = mailtm_create_mailbox(proxies=proxies)
            if not result:
                self.log("[!] Mail.tm 创建邮箱失败")
                return None
            email, mail_token, _ = result
            self.log(f"[*] 注册邮箱: {email}")

            # 2. 初始化 OAuth
            state = _random_state()
            code_verifier = _pkce_verifier()
            code_challenge = _sha256_b64url_no_pad(code_verifier)

            params = {
                "client_id": CLIENT_ID,
                "response_type": "code",
                "redirect_uri": DEFAULT_REDIRECT_URI,
                "scope": DEFAULT_SCOPE,
                "state": state,
                "code_challenge": code_challenge,
                "code_challenge_method": "S256",
                "prompt": "login",
                "id_token_add_organizations": "true",
                "codex_cli_simplified_flow": "true",
            }
            auth_url = f"{AUTH_URL}?{urllib.parse.urlencode(params)}"

            # 3. 访问并获取 did
            s.get(auth_url, timeout=15)
            did = s.cookies.get("oai-did")
            if not did:
                return None

            # 4. Sentinel
            sen_req_body = f'{{"p":"","id":"{did}","flow":"authorize_continue"}}'
            sen_resp = s.post(
                "https://sentinel.openai.com/backend-api/sentinel/req",
                headers={
                    "origin": "https://sentinel.openai.com",
                    "content-type": "text/plain;charset=UTF-8",
                },
                data=sen_req_body,
                timeout=15,
            )
            sen_token = sen_resp.json()["token"]
            sentinel = f'{{"p": "", "t": "", "c": "{sen_token}", "id": "{did}", "flow": "authorize_continue"}}'

            # 5. Continue
            signup_body = f'{{"username":{{"value":"{email}","kind":"email"}},"screen_hint":"signup"}}'
            s.post(
                "https://auth.openai.com/api/accounts/authorize/continue",
                headers={
                    "openai-sentinel-token": sentinel,
                    "content-type": "application/json",
                },
                data=signup_body,
            )

            # 6. Password
            password = _generate_password()
            s.post(
                "https://auth.openai.com/api/accounts/user/register",
                headers={"content-type": "application/json"},
                data=json.dumps({"password": password, "username": email}),
            )

            # 7. Send OTP
            s.get("https://auth.openai.com/api/accounts/email-otp/send")

            # 8. 通过 Mail.tm 轮询验证码
            self.log("[*] 等待验证码...")
            code = mailtm_wait_otp(mail_token, timeout=150, interval=3, proxies=proxies)

            if not code:
                return None
            self.log(f"[+] 捕获验证码: {code}")

            # 9. Validate
            val_resp = s.post(
                "https://auth.openai.com/api/accounts/email-otp/validate",
                headers={
                    "accept": "application/json",
                    "content-type": "application/json",
                    "referer": "https://auth.openai.com/email-verification",
                    "origin": "https://auth.openai.com",
                },
                data=json.dumps({"code": code}),
            )
            self.log(f"[*] 验证码校验状态: {val_resp.status_code}")
            if val_resp.status_code != 200:
                self.log(f"[!] 校验失败响应: {val_resp.text}")
                return None

            # 10. Create
            create_resp = s.post(
                "https://auth.openai.com/api/accounts/create_account",
                headers={
                    "accept": "application/json",
                    "content-type": "application/json",
                    "referer": "https://auth.openai.com/about-you",
                    "origin": "https://auth.openai.com",
                },
                data='{"name":"Neo","birthdate":"2000-02-20"}',
            )
            self.log(f"[*] 账户创建状态: {create_resp.status_code}")

            if create_resp.status_code != 200:
                self.log(f"[!] 账户创建失败详情: {create_resp.text}")
                return None

            # 11. 获取 Workspace ID (三重保险提取法)
            auth_cookie = s.cookies.get("oai-client-auth-session") or ""
            workspace_id = None
            resp_text = create_resp.text

            # 尝试解析 JSON
            try:
                rj = create_resp.json()
                if isinstance(rj, dict):
                    ws_info = rj.get("workspaces") or []
                    if ws_info and isinstance(ws_info, list):
                        workspace_id = ws_info[0].get("id")
                    elif str(rj.get("id", "")).startswith("ws-"):
                        workspace_id = rj.get("id")
            except:
                pass

            # 辅助提取：从 Cookie 字符串正则匹配
            if not workspace_id and auth_cookie:
                ws_match = re.search(r"ws-[a-zA-Z0-9]+", auth_cookie)
                if ws_match:
                    workspace_id = ws_match.group(0)

            # 辅助提取：从 JWT Cookie Payload 提取
            if not workspace_id and auth_cookie:
                for seg in auth_cookie.split("."):
                    try:
                        decoded = _decode_jwt_segment(seg)
                        if isinstance(decoded, dict):
                            ws_list = decoded.get("workspaces") or []
                            if ws_list:
                                workspace_id = ws_list[0].get("id")
                                break
                    except:
                        continue

            if not workspace_id:
                self.log(f"[!] 无法锁定 Workspace ID. 响应长度: {len(resp_text)}")
                if resp_text.strip().startswith("<!DOCTYPE"):
                    self.log("[!] 收到 HTML 响应，可能是被重定向或风控。内容预览:")
                    self.log("-" * 40)
                    self.log(resp_text[:2000])
                    self.log("-" * 40)
                else:
                    self.log(f"[!] 响应内容: {resp_text[:500]}")
                return None

            self.log(f"[*] 锁定 Workspace ID: {workspace_id}")

            select_resp = s.post(
                "https://auth.openai.com/api/accounts/workspace/select",
                headers={
                    "content-type": "application/json",
                    "referer": "https://auth.openai.com/sign-in-with-chatgpt/codex/consent",
                    "origin": "https://auth.openai.com",
                },
                data=json.dumps({"workspace_id": workspace_id}),
            )

            res_data = select_resp.json()
            continue_url = res_data.get("continue_url")
            self.log(f"[*] 获取 Continue URL 状态: {select_resp.status_code}")
            if not continue_url:
                self.log(f"[!] 缺失 continue_url: {res_data}")
                return None

            # 12. OAuth Chain
            curr_url = continue_url
            for _ in range(6):
                r = s.get(curr_url, allow_redirects=False, timeout=15)
                loc = r.headers.get("Location")
                if not loc:
                    break
                curr_url = urllib.parse.urljoin(curr_url, loc)
                if "code=" in curr_url:
                    cb = _parse_callback_url(curr_url)
                    t_payload = {
                        "grant_type": "authorization_code",
                        "client_id": CLIENT_ID,
                        "code": cb["code"],
                        "redirect_uri": DEFAULT_REDIRECT_URI,
                        "code_verifier": code_verifier,
                    }
                    t_resp = requests.post(
                        TOKEN_URL, data=t_payload, impersonate="chrome"
                    ).json()

                    id_token = t_resp.get("id_token")
                    claims = _jwt_claims_no_verify(id_token)
                    auth_claims = claims.get("https://api.openai.com/auth") or {}

                    config = {
                        "id_token": id_token,
                        "access_token": t_resp.get("access_token"),
                        "refresh_token": t_resp.get("refresh_token"),
                        "account_id": auth_claims.get("chatgpt_account_id"),
                        "email": email,
                        "type": "codex",
                        "plan": auth_claims.get("chatgpt_plan_type", "free"),
                        "expired": time.strftime(
                            "%Y-%m-%dT%H:%M:%SZ",
                            time.gmtime(time.time() + int(t_resp.get("expires_in", 0))),
                        ),
                        "last_refresh": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    }
                    token_json_str = json.dumps(config)

                    # 保存到本地 output 目录
                    try:
                        os.makedirs(OUTPUT_DIR, exist_ok=True)
                        fname = f"token_{email.replace('@', '_')}_{int(time.time())}.json"
                        fpath = os.path.join(OUTPUT_DIR, fname)
                        with open(fpath, "w", encoding="utf-8") as f:
                            f.write(token_json_str)
                        self.log(f"[+] Token 已保存: {fpath}")
                        # 注入 CLIProxyAPI auth 目录 + new-api 渠道
                        if inject_token:
                            inject_token(fpath)
                        elif add_channel_to_newapi:
                            add_channel_to_newapi(config)
                    except Exception as ie:
                        self.log(f"[!] 本地保存/注入失败: {ie}")

                    return token_json_str

            return None
        except Exception as e:
            self.log(f"[!] 出错: {e}")
            return None
        finally:
            pass

    def start(self):
        self.log(f"[+] Mail.tm 邮件模式启动")
        self.log(f"[+] 目标账号数: {self.target}")

        last_check_time = 0
        while True:
            now = time.time()
            if now - last_check_time >= self.check_interval:
                current_count = self.check_and_cleanup()
                last_check_time = now
            else:
                current_count = len(self.get_remote_accounts())

            self.log(f"[*] 当前存量: {current_count} / 目标: {self.target}")

            if current_count < self.target:
                token_json = self.register_one()
                if token_json:
                    self.log("[+] 注册成功，token 已注入 new-api")
                    # CLIProxyAPI 上传是可选的，失败不影响
                    if not self.upload_token_data(token_json):
                        self.log("[*] CLIProxyAPI 上传跳过（未运行）")
                    self.current_reg_delay = random.randint(
                        self.reg_delay_min, self.reg_delay_max
                    )
                else:
                    self.log("[!] 注册失败，退避等待")
                    self.current_reg_delay = min(self.current_reg_delay * 2, 3600)

                time.sleep(self.current_reg_delay)
            else:
                time.sleep(60)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="ChatGPT 账号全自动管理脚本 (单一脚本版)"
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("CLIPROXYAPI_URL", "http://cliproxyapi:8317"),
        help="CLIProxyAPI 地址",
    )
    parser.add_argument(
        "--mgmt-key",
        default=os.environ.get("CLIPROXYAPI_MGMT_KEY", ""),
        help="管理密钥",
    )
    parser.add_argument(
        "--target",
        type=int,
        default=int(os.environ.get("MANAGER_TARGET", "100")),
        help="账号目标数量",
    )
    parser.add_argument("--check-interval", type=int, default=3600, help="检测间隔")
    parser.add_argument("--reg-delay-min", type=int, default=60, help="最小延迟")
    parser.add_argument("--reg-delay-max", type=int, default=120, help="最大延迟")
    parser.add_argument(
        "--proxy",
        default=os.environ.get("PROXY_URL", None),
        help="代理",
    )
    args = parser.parse_args()

    if not args.mgmt_key:
        print("[!] 缺少 --mgmt-key 或 CLIPROXYAPI_MGMT_KEY 环境变量")
        sys.exit(1)

    try:
        ChatGPTManager(args).start()
    except KeyboardInterrupt:
        print("\n[*] 已停止。")
