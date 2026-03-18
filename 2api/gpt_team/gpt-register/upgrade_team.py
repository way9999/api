#!/usr/bin/env python3
"""
upgrade_team.py — 一键绑卡升级 ChatGPT Team + 提取 Token
使用 Playwright + LLM ReAct 智能体驱动浏览器操作

输入：
  - OpenAI session token (access_token 或 cookie)
  - 信用卡信息 (卡号、过期日期、CVV、账单地址)
输出：
  - Team workspace 的 OAuth token JSON
"""
import argparse
import json
import os
import random
import re
import sys
import time
import traceback
from pathlib import Path

from openai import OpenAI
from playwright.sync_api import sync_playwright, Page, Browser, BrowserContext
from playwright_stealth import Stealth

from register import (
    generate_oauth_url,
    submit_callback_url,
)

# ── 配置 ──
LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "http://new-api:3000/v1")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "sk-xxx")
LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-4o")
PROXY_URL = os.environ.get("PROXY_URL", "")
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/app/output")
HEADLESS = os.environ.get("HEADLESS", "true").lower() in ("true", "1", "yes")

DOM_JS = (Path(__file__).parent / "dom_extract.js").read_text(encoding="utf-8")

SYSTEM_PROMPT = """你是一个浏览器自动化智能体，负责完成用户指定的网页操作任务。

## 当前页面 DOM
页面内容以简化文本表示，交互元素带有 [idx] 索引标记，例如：
  [0]<button>登录 />
  [3]<input placeholder="邮箱" />

## 可用动作
每次回复一个 JSON 对象，包含 thought 和 action：

- click: {"thought":"...", "action":"click", "params":{"idx":5}}
- fill: {"thought":"...", "action":"fill", "params":{"idx":3, "text":"hello"}}
- select: {"thought":"...", "action":"select", "params":{"idx":7, "value":"US"}}
- press: {"thought":"...", "action":"press", "params":{"key":"Enter"}}
- scroll: {"thought":"...", "action":"scroll", "params":{"direction":"down"}}
- wait: {"thought":"...", "action":"wait", "params":{"seconds":3}}
- switch_tab: {"thought":"...", "action":"switch_tab", "params":{"index":0}}
- goto: {"thought":"...", "action":"goto", "params":{"url":"https://..."}}
- done: {"thought":"...", "action":"done", "params":{"result":"任务完成描述"}}
- fail: {"thought":"...", "action":"fail", "params":{"reason":"失败原因"}}

## 规则
1. 每次只返回一个动作的 JSON，不要多余文字
2. fill 会先清空输入框再填入文本
3. 仔细观察 DOM 变化判断操作是否成功
4. 如果页面没变化，可能需要等待加载
5. 遇到验证码或人机验证，描述你看到的内容
6. Stripe 支付表单可能在 iframe 里，如果看不到卡号输入框，说明需要切换到 iframe
"""


def _parse_proxy(proxy_url: str) -> dict:
    from urllib.parse import urlparse
    parsed = urlparse(proxy_url)
    result = {"server": f"{parsed.scheme}://{parsed.hostname}:{parsed.port}"}
    if parsed.username:
        result["username"] = parsed.username
        result["password"] = parsed.password or ""
    return result


def log(msg: str):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] [upgrade] {msg}", flush=True)


class BrowserAgent:
    def __init__(self, browser: Browser, proxy: str = ""):
        ctx_opts = {
            "viewport": {"width": 1280, "height": 900},
            "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        }
        if proxy:
            ctx_opts["proxy"] = _parse_proxy(proxy)
        self.context: BrowserContext = browser.new_context(**ctx_opts)
        stealth = Stealth()
        stealth.apply_stealth_sync(self.context)
        self.pages: list[Page] = []
        self.current_tab = 0
        self.client = OpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY)
        self.messages = []

    @property
    def page(self) -> Page:
        return self.pages[self.current_tab]

    def new_tab(self, url: str = "") -> Page:
        p = self.context.new_page()
        self.pages.append(p)
        if url:
            p.goto(url, wait_until="domcontentloaded", timeout=60000)
        return p

    def inject_cookies(self, cookies: list[dict]):
        """注入 cookies 到 context"""
        self.context.add_cookies(cookies)

    def extract_dom(self, page: Page | None = None) -> str:
        p = page or self.page
        try:
            result = p.evaluate(DOM_JS)
            text = result.get("text", "")[:25000]
            if not text.strip():
                p.wait_for_timeout(2000)
                result = p.evaluate(DOM_JS)
                text = result.get("text", "")[:25000]
            return text
        except Exception as e:
            return f"[DOM提取失败: {e}]"

    def extract_dom_with_iframes(self, page: Page | None = None) -> str:
        """提取 DOM，包括 iframe 内容（用于 Stripe 支付表单）"""
        p = page or self.page
        main_dom = self.extract_dom(p)
        # 尝试提取 Stripe iframe 内容
        try:
            frames = p.frames
            for frame in frames:
                if "stripe" in (frame.url or "").lower() or "js.stripe.com" in (frame.url or ""):
                    try:
                        iframe_dom = frame.evaluate(DOM_JS)
                        iframe_text = iframe_dom.get("text", "")[:5000]
                        if iframe_text.strip():
                            main_dom += f"\n\n## Stripe iframe 内容:\n{iframe_text}"
                    except Exception:
                        pass
        except Exception:
            pass
        return main_dom

    def call_llm(self, dom_text: str, extra_info: str = "") -> dict:
        user_content = ""
        if extra_info:
            user_content += f"{extra_info}\n\n"
        user_content += f"## 当前页面 DOM\n```\n{dom_text}\n```"

        self.messages.append({"role": "user", "content": user_content})

        if len(self.messages) > 40:
            self.messages = self.messages[-30:]

        resp = self.client.chat.completions.create(
            model=LLM_MODEL,
            messages=[{"role": "system", "content": SYSTEM_PROMPT}] + self.messages,
            temperature=0.2,
            max_tokens=500,
        )
        content = resp.choices[0].message.content.strip()
        self.messages.append({"role": "assistant", "content": content})

        try:
            return json.loads(content)
        except json.JSONDecodeError:
            m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", content, re.DOTALL)
            if m:
                return json.loads(m.group(1))
            m = re.search(r"\{[^{}]*\}", content)
            if m:
                return json.loads(m.group(0))
            raise ValueError(f"LLM 返回非 JSON: {content[:200]}")

    def execute_action(self, action: dict) -> str:
        act = action.get("action", "")
        params = action.get("params", {})
        page = self.page

        try:
            if act == "click":
                el = page.locator(f"[data-pa-idx='{params['idx']}']")
                el.scroll_into_view_if_needed(timeout=3000)
                el.click(timeout=5000)
                page.wait_for_timeout(800)
                return f"clicked [{params['idx']}]"

            elif act == "fill":
                idx = params["idx"]
                text = params["text"]
                # 先尝试主页面
                el = page.locator(f"[data-pa-idx='{idx}']")
                if el.count() > 0:
                    el.scroll_into_view_if_needed(timeout=3000)
                    el.click(timeout=3000)
                    el.fill("", timeout=2000)
                    el.type(text, delay=random.randint(30, 80))
                    page.wait_for_timeout(500)
                    return f"filled [{idx}] with '{text[:20]}...'"
                # 尝试 Stripe iframe
                for frame in page.frames:
                    if "stripe" in (frame.url or "").lower():
                        el = frame.locator(f"[data-pa-idx='{idx}']")
                        if el.count() > 0:
                            el.click(timeout=3000)
                            el.fill("", timeout=2000)
                            el.type(text, delay=random.randint(30, 80))
                            page.wait_for_timeout(500)
                            return f"filled [{idx}] in stripe iframe"
                return f"element [{idx}] not found"

            elif act == "select":
                el = page.locator(f"[data-pa-idx='{params['idx']}']")
                el.select_option(params["value"], timeout=5000)
                page.wait_for_timeout(500)
                return f"selected '{params['value']}'"

            elif act == "press":
                page.keyboard.press(params["key"])
                page.wait_for_timeout(500)
                return f"pressed {params['key']}"

            elif act == "scroll":
                d = params.get("direction", "down")
                delta = 500 if d == "down" else -500
                page.mouse.wheel(0, delta)
                page.wait_for_timeout(500)
                return f"scrolled {d}"

            elif act == "wait":
                secs = min(params.get("seconds", 2), 10)
                page.wait_for_timeout(int(secs * 1000))
                return f"waited {secs}s"

            elif act == "switch_tab":
                idx = params.get("index", 0)
                if 0 <= idx < len(self.pages):
                    self.current_tab = idx
                    self.pages[idx].bring_to_front()
                    return f"switched to tab {idx}"
                return f"invalid tab index {idx}"

            elif act == "goto":
                page.goto(params["url"], wait_until="domcontentloaded", timeout=60000)
                return f"navigated to {params['url'][:60]}"

            elif act == "done":
                return "DONE:" + params.get("result", "")

            elif act == "fail":
                return "FAIL:" + params.get("reason", "unknown")

            else:
                return f"unknown action: {act}"

        except Exception as e:
            return f"action error ({act}): {e}"

    def run_task(self, task: str, max_steps: int = 60) -> str:
        log(f"任务: {task[:100]}...")
        self.messages = [{"role": "user", "content": f"任务: {task}"}]

        for step in range(1, max_steps + 1):
            dom = self.extract_dom_with_iframes()
            log(f"步骤 {step}/{max_steps} | {self.page.url[:60]}")

            try:
                action = self.call_llm(dom)
            except Exception as e:
                log(f"LLM 调用失败: {e}")
                time.sleep(2)
                continue

            thought = action.get("thought", "")
            act_name = action.get("action", "?")
            log(f"  思考: {thought[:100]}")
            log(f"  动作: {act_name} {json.dumps(action.get('params', {}), ensure_ascii=False)[:100]}")

            result = self.execute_action(action)
            log(f"  结果: {result[:120]}")

            if result.startswith("DONE:"):
                return result[5:]
            if result.startswith("FAIL:"):
                raise RuntimeError(result[5:])

            self.messages.append({"role": "user", "content": f"动作执行结果: {result}"})

        raise RuntimeError(f"超过最大步数 {max_steps}")

    def close(self):
        try:
            self.context.close()
        except Exception:
            pass


def build_chatgpt_cookies(access_token: str) -> list[dict]:
    """构建 ChatGPT 登录所需的 cookies"""
    return [
        {
            "name": "oai-did",
            "value": str(__import__("uuid").uuid4()),
            "domain": ".chatgpt.com",
            "path": "/",
        },
    ]


def extract_team_token(agent: BrowserAgent) -> str | None:
    """升级完成后提取 Team workspace 的 OAuth token"""
    log("开始提取 Team token...")
    oauth = generate_oauth_url()
    page = agent.page

    callback_url = None

    def handle_route(route):
        nonlocal callback_url
        callback_url = route.request.url
        route.fulfill(status=200, body="ok")

    page.route("**/auth/callback**", handle_route)

    try:
        page.goto(oauth.auth_url, wait_until="domcontentloaded", timeout=30000)

        for _ in range(20):
            if callback_url:
                break
            page.wait_for_timeout(1000)

        if not callback_url:
            log("未自动跳转，LLM 辅助授权...")
            agent.run_task(
                "当前页面是 OpenAI 授权页面。如果看到 'Authorize'、'Allow'、'Continue' 按钮，点击它。"
                "如果需要选择 workspace，选择 Team workspace。完成后说 done。",
                max_steps=15,
            )
            for _ in range(10):
                if callback_url:
                    break
                page.wait_for_timeout(1000)

        if not callback_url:
            log("OAuth callback 未被拦截")
            return None

        log(f"拦截到 callback: {callback_url[:80]}...")
        token_json = submit_callback_url(
            callback_url=callback_url,
            expected_state=oauth.state,
            code_verifier=oauth.code_verifier,
        )
        return token_json

    except Exception as e:
        log(f"Token 提取失败: {e}")
        return None
    finally:
        page.unroute("**/auth/callback**")


def save_token(token_json: str) -> str:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    data = json.loads(token_json)
    email = data.get("email", "unknown")
    ts = time.strftime("%Y%m%d_%H%M%S")
    filename = f"token_team_{ts}_{email.split('@')[0]}.json"
    filepath = os.path.join(OUTPUT_DIR, filename)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(token_json)
    log(f"Token 已保存: {filepath}")
    return filepath


def upgrade_to_team(
    browser: Browser,
    access_token: str,
    card_number: str,
    card_expiry: str,
    card_cvc: str,
    billing_name: str,
    billing_address: str = "",
    billing_city: str = "",
    billing_state: str = "",
    billing_zip: str = "",
    billing_country: str = "US",
    team_name: str = "My Team",
    proxy: str = "",
) -> str | None:
    """一键绑卡升级 Team 并提取 token"""
    agent = BrowserAgent(browser, proxy=proxy)
    try:
        # 注入 access_token 作为 Authorization header
        # ChatGPT 使用 __Secure-next-auth.session-token cookie 或 Authorization header
        # 我们通过 localStorage 或直接设置 cookie 来登录
        page = agent.new_tab("https://chatgpt.com")

        # 等待页面加载
        page.wait_for_timeout(3000)

        # 注入 access_token 到 localStorage 和 cookie
        page.evaluate(f"""
            try {{
                // 设置 access token
                window.__session = {{accessToken: "{access_token}"}};
            }} catch(e) {{}}
        """)

        # 设置 authorization cookie
        agent.context.add_cookies([
            {
                "name": "__Secure-next-auth.session-token",
                "value": access_token,
                "domain": ".chatgpt.com",
                "path": "/",
                "secure": True,
                "httpOnly": True,
            },
        ])

        # 刷新页面使 cookie 生效
        page.reload(wait_until="domcontentloaded", timeout=30000)
        page.wait_for_timeout(3000)

        # 导航到升级页面
        log("导航到 Team 升级页面...")
        task = (
            f"我需要将 ChatGPT 账号升级到 Team 计划。\n\n"
            f"步骤：\n"
            f"1. 如果当前页面需要登录，先完成登录\n"
            f"2. 找到升级到 Team 计划的入口（可能在设置、定价页面、或侧边栏）\n"
            f"3. 如果需要创建 Team workspace，名称填: {team_name}\n"
            f"4. 进入付款页面后，填写信用卡信息：\n"
            f"   - 卡号: {card_number}\n"
            f"   - 过期日期: {card_expiry}\n"
            f"   - CVC/CVV: {card_cvc}\n"
            f"   - 持卡人姓名: {billing_name}\n"
            f"   - 账单地址: {billing_address}\n"
            f"   - 城市: {billing_city}\n"
            f"   - 州/省: {billing_state}\n"
            f"   - 邮编: {billing_zip}\n"
            f"   - 国家: {billing_country}\n"
            f"5. 确认付款完成升级\n"
            f"6. 升级完成后回复 done\n\n"
            f"注意：\n"
            f"- 信用卡表单可能在 Stripe iframe 里\n"
            f"- 如果看到 'Subscribe' 或 '订阅' 按钮，点击它\n"
            f"- 如果需要选择座位数，选择最少的（通常是 2）\n"
            f"- 如果需要选择年付/月付，选择月付\n"
            f"- 不要导航离开付款流程"
        )

        result = agent.run_task(task)
        log(f"升级流程完成: {result}")

        # 提取 Team token
        token_json = extract_team_token(agent)
        if token_json:
            filepath = save_token(token_json)
            log(f"Team token 提取成功: {filepath}")
            return token_json
        else:
            log("未能提取 Team token")
            return None

    except Exception as e:
        log(f"升级失败: {e}")
        traceback.print_exc()
        return None
    finally:
        agent.close()


def main():
    parser = argparse.ArgumentParser(description="一键绑卡升级 ChatGPT Team + 提取 Token")
    parser.add_argument("--token", required=True, help="OpenAI access_token 或 session token")
    parser.add_argument("--card-number", required=True, help="信用卡号")
    parser.add_argument("--card-expiry", required=True, help="过期日期 (MM/YY)")
    parser.add_argument("--card-cvc", required=True, help="CVC/CVV")
    parser.add_argument("--billing-name", required=True, help="持卡人姓名")
    parser.add_argument("--billing-address", default="", help="账单地址")
    parser.add_argument("--billing-city", default="", help="城市")
    parser.add_argument("--billing-state", default="", help="州/省")
    parser.add_argument("--billing-zip", default="", help="邮编")
    parser.add_argument("--billing-country", default="US", help="国家代码")
    parser.add_argument("--team-name", default="My Team", help="Team 名称")
    parser.add_argument("--proxy", default=PROXY_URL, help="代理地址")
    args = parser.parse_args()

    log("启动 ChatGPT Team 升级")
    log(f"  LLM: {LLM_BASE_URL} / {LLM_MODEL}")
    log(f"  代理: {args.proxy or '无'}")

    with sync_playwright() as pw:
        launch_opts = {
            "headless": HEADLESS,
            "args": [
                "--disable-blink-features=AutomationControlled",
                "--no-sandbox",
                "--disable-dev-shm-usage",
            ],
        }
        browser = pw.chromium.launch(**launch_opts)

        result = upgrade_to_team(
            browser=browser,
            access_token=args.token,
            card_number=args.card_number,
            card_expiry=args.card_expiry,
            card_cvc=args.card_cvc,
            billing_name=args.billing_name,
            billing_address=args.billing_address,
            billing_city=args.billing_city,
            billing_state=args.billing_state,
            billing_zip=args.billing_zip,
            billing_country=args.billing_country,
            team_name=args.team_name,
            proxy=args.proxy,
        )

        browser.close()

        if result:
            log("升级成功!")
            print(result)
        else:
            log("升级失败")
            sys.exit(1)


if __name__ == "__main__":
    main()
