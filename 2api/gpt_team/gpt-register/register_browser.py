#!/usr/bin/env python3
"""
register_browser.py — Playwright 无头浏览器 + LLM ReAct 智能体自动注册 ChatGPT
借鉴 page-agent DOM 提取思路，LLM 驱动浏览器操作
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

# ── 从 register.py 复用 OAuth 函数 ──
from register import (
    generate_oauth_url,
    submit_callback_url,
    OAuthStart,
)

# ── 配置 ──
LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "http://new-api:3000/v1")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "sk-xxx")
LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-4o")
PROXY_URL = os.environ.get("PROXY_URL", "")
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/app/output")
AUTH_DIR = os.environ.get("AUTH_DIR", "/auth")
MAX_STEPS = int(os.environ.get("MAX_STEPS", "60"))
HEADLESS = os.environ.get("HEADLESS", "true").lower() in ("true", "1", "yes")

MAIL_URL = "https://mail.chatgpt.org.uk/"

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
"""

def _parse_proxy(proxy_url: str) -> dict:
    """解析代理 URL 为 Playwright proxy 配置，分离 username/password"""
    from urllib.parse import urlparse
    parsed = urlparse(proxy_url)
    result = {"server": f"{parsed.scheme}://{parsed.hostname}:{parsed.port}"}
    if parsed.username:
        result["username"] = parsed.username
        result["password"] = parsed.password or ""
    return result


def log(msg: str):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] [browser] {msg}", flush=True)


class BrowserAgent:
    def __init__(self, browser: Browser, proxy: str = ""):
        self.browser = browser
        self.proxy = proxy
        # 主 context（走代理，用于 OpenAI 注册）
        ctx_opts = {
            "viewport": {"width": 1280, "height": 800},
            "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        }
        if proxy:
            ctx_opts["proxy"] = _parse_proxy(proxy)
        self.context: BrowserContext = browser.new_context(**ctx_opts)
        # stealth: 全面隐藏自动化特征
        stealth = Stealth()
        stealth.apply_stealth_sync(self.context)
        # 直连 context（用于邮箱等不需要代理的站点）
        self.direct_context: BrowserContext = browser.new_context(
            viewport={"width": 1280, "height": 800}
        )
        self.pages: list[Page] = []
        self.page_contexts: list[str] = []  # "proxy" or "direct"
        self.current_tab = 0
        self.client = OpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY)
        self.messages = []

    @property
    def page(self) -> Page:
        return self.pages[self.current_tab]

    def new_tab(self, url: str = "", direct: bool = False) -> Page:
        ctx = self.direct_context if direct else self.context
        p = ctx.new_page()
        self.pages.append(p)
        self.page_contexts.append("direct" if direct else "proxy")
        if url:
            p.goto(url, wait_until="domcontentloaded", timeout=60000)
            # 等待 Cloudflare challenge 完成（最多 20 秒）
            if not direct:
                for _ in range(10):
                    title = p.title()
                    if "just a moment" not in title.lower():
                        break
                    log(f"  等待 Cloudflare challenge... ({title})")
                    p.wait_for_timeout(2000)
        return p

    def extract_dom(self, page: Page | None = None) -> str:
        p = page or self.page
        try:
            result = p.evaluate(DOM_JS)
            text = result.get("text", "")[:25000]
            # 如果 DOM 为空，可能还在加载，等一下再试
            if not text.strip():
                p.wait_for_timeout(2000)
                result = p.evaluate(DOM_JS)
                text = result.get("text", "")[:25000]
            return text
        except Exception as e:
            return f"[DOM提取失败: {e}]"

    def call_llm(self, dom_text: str, tab_info: str = "") -> dict:
        user_content = ""
        if tab_info:
            user_content += f"## 标签页信息\n{tab_info}\n\n"
        user_content += f"## 当前页面 DOM\n```\n{dom_text}\n```"

        self.messages.append({"role": "user", "content": user_content})

        # 保留最近 20 轮对话避免 token 溢出
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

        # 解析 JSON
        try:
            # 尝试直接解析
            return json.loads(content)
        except json.JSONDecodeError:
            # 尝试从 markdown code block 提取
            m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", content, re.DOTALL)
            if m:
                return json.loads(m.group(1))
            # 尝试找第一个 JSON 对象
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
                el = page.locator(f"[data-pa-idx='{params['idx']}']")
                el.scroll_into_view_if_needed(timeout=3000)
                el.click(timeout=3000)
                el.fill("", timeout=2000)
                el.type(params["text"], delay=random.randint(30, 80))
                page.wait_for_timeout(500)
                return f"filled [{params['idx']}] with '{params['text'][:30]}'"

            elif act == "select":
                el = page.locator(f"[data-pa-idx='{params['idx']}']")
                el.select_option(params["value"], timeout=5000)
                page.wait_for_timeout(500)
                return f"selected '{params['value']}' on [{params['idx']}]"

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
                    self.pages[idx].wait_for_timeout(500)
                    return f"switched to tab {idx} ({self.pages[idx].url[:60]})"
                return f"invalid tab index {idx}, have {len(self.pages)} tabs"

            elif act == "goto":
                page.goto(params["url"], wait_until="domcontentloaded", timeout=30000)
                return f"navigated to {params['url'][:60]}"

            elif act == "done":
                return "DONE:" + params.get("result", "")

            elif act == "fail":
                return "FAIL:" + params.get("reason", "unknown")

            else:
                return f"unknown action: {act}"

        except Exception as e:
            return f"action error ({act}): {e}"

    def tab_info(self) -> str:
        lines = []
        for i, p in enumerate(self.pages):
            marker = " (当前)" if i == self.current_tab else ""
            lines.append(f"  [{i}] {p.url[:80]}{marker}")
        return "标签页列表:\n" + "\n".join(lines)

    def run_task(self, task: str) -> str:
        """ReAct 主循环"""
        log(f"任务: {task}")
        self.messages = [{"role": "user", "content": f"任务: {task}"}]

        for step in range(1, MAX_STEPS + 1):
            dom = self.extract_dom()
            tabs = self.tab_info()
            log(f"步骤 {step}/{MAX_STEPS} | tab={self.current_tab} | {self.page.url[:60]}")

            try:
                action = self.call_llm(dom, tabs)
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

            # 把执行结果反馈给 LLM
            self.messages.append({"role": "user", "content": f"动作执行结果: {result}"})

        raise RuntimeError(f"超过最大步数 {MAX_STEPS}")

    def close(self):
        try:
            self.context.close()
        except Exception:
            pass
        try:
            self.direct_context.close()
        except Exception:
            pass



def save_token(token_json: str) -> str | None:
    """保存 token 到 output 目录，返回文件路径"""
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    data = json.loads(token_json)
    email = data.get("email", "unknown")
    ts = time.strftime("%Y%m%d_%H%M%S")
    filename = f"token_{ts}_{email.split('@')[0]}.json"
    filepath = os.path.join(OUTPUT_DIR, filename)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(token_json)
    log(f"Token 已保存: {filepath}")
    return filepath


def inject_token(filepath: str):
    """调用 inject.py 注入单个 token"""
    try:
        import inject
        inject.inject_token(filepath)
        log(f"Token 已注入 auth 目录")
    except Exception as e:
        log(f"注入失败: {e}")


def register_one(browser: Browser, proxy: str = "") -> bool:
    """单次注册流程"""
    agent = BrowserAgent(browser, proxy=proxy)
    try:
        # 生成 OAuth URL 初始化 session（带 PKCE 参数）
        oauth = generate_oauth_url()

        # Tab 0: 邮箱服务（直连，不走代理）
        log("打开临时邮箱服务...")
        agent.new_tab(MAIL_URL, direct=True)

        # Tab 1: 通过 OAuth URL 进入注册流程（会自动跳转到 auth.openai.com 登录/注册页）
        log("通过 OAuth URL 打开注册页...")
        agent.new_tab(oauth.auth_url)
        agent.current_tab = 1

        task = (
            "帮我注册一个 ChatGPT 帐号。当前页面是 OpenAI 的登录/注册页面。\n"
            "步骤：\n"
            "1. 先切换到 tab 0（邮箱页面 mail.chatgpt.org.uk），记住临时邮箱地址\n"
            "2. 切换回 tab 1（OpenAI 页面）\n"
            "3. 在页面上找到 email/邮箱输入框，填入临时邮箱地址\n"
            "4. 点击 Continue 按钮提交邮箱\n"
            "5. 如果出现注册表单，填写名称（随机英文名）和生日（确保满 18 岁，选 2000 年或更早）\n"
            "6. 当需要邮箱验证码时，切换到 tab 0 查看收到的验证邮件，获取 6 位数验证码\n"
            "7. 切换回 tab 1 填入验证码\n"
            "8. 完成所有步骤后回复 done\n\n"
            "重要规则：\n"
            "- 绝对不要点击 'Log in' 或 '登录' 链接！只在当前页面操作\n"
            "- 绝对不要导航到 chatgpt.com！只在 auth.openai.com 域名下操作\n"
            "- 如果看到 'Sign up' 链接，点击它进入注册模式\n"
            "- 如果页面显示 'session expired' 或会话过期，回复 fail\n"
            "- 注册是 passwordless 的，不需要设置密码\n"
            "- 如果遇到人机验证（CAPTCHA/Turnstile），等待几秒让它自动完成"
        )

        result = agent.run_task(task)
        log(f"注册流程完成: {result}")

        # 提取 token — 复用同一个 OAuth 参数
        log("开始 OAuth token 提取...")
        token_json = _extract_token_same_oauth(agent, oauth)
        if token_json:
            filepath = save_token(token_json)
            if filepath:
                inject_token(filepath)
            return True
        else:
            log("未能提取 token，但注册可能已成功")
            return False

    except Exception as e:
        log(f"注册失败: {e}")
        traceback.print_exc()
        return False
    finally:
        agent.close()


def _extract_token_same_oauth(agent: BrowserAgent, oauth: OAuthStart) -> str | None:
    """注册完成后，用同一个 OAuth session 提取 token"""
    page = agent.page
    callback_url = None

    def handle_route(route):
        nonlocal callback_url
        callback_url = route.request.url
        route.fulfill(status=200, body="ok")

    page.route("**/auth/callback**", handle_route)

    try:
        # 注册完成后浏览器已经在 auth.openai.com 上且已登录
        # 重新导航到 OAuth URL，应该自动跳转到 callback
        page.goto(oauth.auth_url, wait_until="domcontentloaded", timeout=30000)

        for _ in range(20):
            if callback_url:
                break
            page.wait_for_timeout(1000)

        if not callback_url:
            log("未拦截到 OAuth callback，尝试 LLM 辅助授权...")
            agent.run_task(
                "当前页面是 OpenAI 授权页面。如果看到 'Authorize'、'Allow'、'Continue' 按钮，点击它。完成后说 done。"
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
        log(f"OAuth token 提取失败: {e}")
        return None
    finally:
        page.unroute("**/auth/callback**")


def main():
    parser = argparse.ArgumentParser(description="Playwright + LLM 浏览器自动注册 ChatGPT")
    parser.add_argument("--proxy", default=PROXY_URL, help="代理地址")
    parser.add_argument("--once", action="store_true", help="只注册一次")
    parser.add_argument("--count", type=int, default=0, help="注册数量（0=无限循环）")
    args = parser.parse_args()

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    os.makedirs(AUTH_DIR, exist_ok=True)

    log(f"启动浏览器自动注册")
    log(f"  LLM: {LLM_BASE_URL} / {LLM_MODEL}")
    log(f"  代理: {args.proxy or '无'}")
    log(f"  无头模式: {HEADLESS}")

    with sync_playwright() as pw:
        launch_opts = {
            "headless": HEADLESS,
            "args": [
                "--disable-blink-features=AutomationControlled",
                "--disable-features=IsolateOrigins,site-per-process",
                "--no-sandbox",
                "--disable-setuid-sandbox",
                "--disable-dev-shm-usage",
            ],
        }
        browser = pw.chromium.launch(**launch_opts)

        round_num = 0
        success = 0
        try:
            while True:
                round_num += 1
                log(f"===== 第 {round_num} 轮注册 =====")
                if register_one(browser, proxy=args.proxy):
                    success += 1
                    log(f"成功 {success}/{round_num}")
                else:
                    log(f"失败，成功率 {success}/{round_num}")

                if args.once:
                    break
                if args.count > 0 and success >= args.count:
                    log(f"已达到目标数量 {args.count}")
                    break

                # 间隔一下再继续
                wait = random.randint(5, 15)
                log(f"等待 {wait}s 后开始下一轮...")
                time.sleep(wait)
        except KeyboardInterrupt:
            log("用户中断")
        finally:
            browser.close()
            log(f"总计: {round_num} 轮, 成功 {success}")


if __name__ == "__main__":
    main()
