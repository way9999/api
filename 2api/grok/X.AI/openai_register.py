#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
临时邮箱服务 - 使用 Cloudflare Temp Email API
配置说明：
1. 将 WORKER_URL 改为你的 Worker 地址（例如：https://mail.example.com）
2. 将 ADMIN_PASSWORD 改为你的管理员密码
3. 将 EMAIL_DOMAIN 改为你的邮箱域名（例如：example.com）
4. 如果启用了网站密码，取消注释 SITE_PASSWORD 并填写
"""

import requests
import time
import secrets
import re
import random
import string

# ========== 配置区域 ==========
WORKER_URL = ""  # 你的 Worker 地址
ADMIN_PASSWORD = ""  # 你的管理员密码
EMAIL_DOMAIN = ""  # 你的邮箱域名
SITE_PASSWORD = None  # 如果启用了网站密码，填写这里，例如："your_site_password"
# =============================


def _generate_random_name():
    """生成随机邮箱用户名"""
    letters1 = ''.join(random.choices(string.ascii_lowercase, k=5))
    numbers = ''.join(random.choices(string.digits, k=random.randint(1, 3)))
    letters2 = ''.join(random.choices(string.ascii_lowercase, k=random.randint(1, 3)))
    return letters1 + numbers + letters2


def get_email_and_token():
    """创建临时邮箱并返回邮箱地址和 JWT token"""
    try:
        name = _generate_random_name()
        
        # 确保 URL 格式正确
        worker_url = WORKER_URL.rstrip('/')
        
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
        
        # 如果启用了网站密码
        if SITE_PASSWORD:
            headers['x-custom-auth'] = SITE_PASSWORD
        
        data = {
            "enablePrefix": True,
            "name": name,
            "domain": EMAIL_DOMAIN,
        }
        
        # 使用普通用户 API 端点（不需要 admin 密码）
        resp = requests.post(
            f"{worker_url}/api/new_address",
            json=data,
            headers=headers,
            timeout=15
        )
        
        if resp.status_code not in [200, 201]:
            raise Exception(f"创建邮箱失败，状态码: {resp.status_code}, 响应: {resp.text}")
        
        result = resp.json()
        email = result.get("address", "")
        jwt_token = result.get("jwt", "")
        
        if not email or not jwt_token:
            raise Exception(f"响应数据不完整: {result}")
        
        print(f"✅ 已创建临时邮箱: {email}")
        return email, jwt_token
        
    except Exception as e:
        print(f"❌ 创建邮箱失败: {e}")
        raise


def get_oai_code(token, email, timeout=180):
    """轮询邮箱获取验证码"""
    print(f"📧 等待验证码邮件", end="", flush=True)
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }
    
    # 如果启用了网站密码
    if SITE_PASSWORD:
        headers['x-custom-auth'] = SITE_PASSWORD
    
    deadline = time.time() + timeout
    seen_ids = set()
    
    while time.time() < deadline:
        print(".", end="", flush=True)
        try:
            # 获取邮件列表
            resp = requests.get(
                f"{WORKER_URL}/api/mails?limit=20&offset=0",
                headers=headers,
                timeout=15
            )
            
            if resp.status_code != 200:
                time.sleep(3)
                continue
            
            data = resp.json()
            
            # 尝试多种可能的数据结构
            messages = []
            if isinstance(data, list):
                messages = data
            elif isinstance(data, dict):
                # 尝试常见的键名
                for key in ['results', 'mails', 'messages', 'data', 'items', 'list']:
                    if key in data and isinstance(data[key], list):
                        messages = data[key]
                        break
            
            if not messages:
                time.sleep(3)
                continue
            
            # 查找验证码邮件
            for msg in messages:
                if not isinstance(msg, dict):
                    continue
                
                msg_id = str(msg.get("id", ""))
                if not msg_id or msg_id in seen_ids:
                    continue
                
                seen_ids.add(msg_id)
                
                # 尝试多种可能的字段名
                subject = str(msg.get("subject", "") or msg.get("Subject", ""))
                message_from = str(msg.get("message_from", "") or msg.get("from", "") or msg.get("From", "")).lower()
                
                # 尝试多种内容字段
                raw = str(msg.get("raw", "") or msg.get("text", "") or msg.get("body", "") or 
                         msg.get("html", "") or msg.get("content", ""))
                
                # 检查是否是 OpenAI 或 x.ai 的验证码邮件
                content = f"{subject}\n{message_from}\n{raw}".lower()
                
                if "openai" not in content and "x.ai" not in content and "xai" not in content and "grok" not in content:
                    continue
                
                # 提取验证码 - x.ai 使用字母数字混合格式（如 G8V-UPX）
                patterns = [
                    r'\b([A-Z0-9]{3}-[A-Z0-9]{3})\b',  # x.ai 格式: G8V-UPX
                    r'code[:\s]+([A-Z0-9]{3}-[A-Z0-9]{3})',  # code: G8V-UPX
                    r'验证码[：:\s]+([A-Z0-9]{3}-[A-Z0-9]{3})',  # 验证码：G8V-UPX
                    r'(?<!\d)(\d{6})(?!\d)',  # 纯数字 6 位（OpenAI 格式）
                    r'code[:\s]+(\d{6})',      # code: 123456
                    r'验证码[：:\s]+(\d{6})',   # 验证码：123456
                ]
                
                for pattern in patterns:
                    code_match = re.search(pattern, raw, re.IGNORECASE)
                    if code_match:
                        code = code_match.group(1)
                        # x.ai 的验证码可能需要去掉连字符
                        # 返回去掉连字符的版本（例如 AX7-BEO -> AX7BEO）
                        code_clean = code.replace('-', '')
                        print(f"\n🔑 验证码: {code} → {code_clean}")
                        return code_clean
            
            time.sleep(3)
            
        except Exception as e:
            print(f"\n⚠️  获取邮件时出错: {e}")
            time.sleep(3)
    
    print("\n❌ 超时，未收到验证码")
    raise Exception("获取验证码超时")


if __name__ == "__main__":
    # 测试
    print("\n" + "=" * 70)
    print("  🧪 测试 Cloudflare Temp Email API")
    print("=" * 70 + "\n")
    
    try:
        email, token = get_email_and_token()
        print(f"📧 邮箱: {email}")
        print(f"🔐 Token: {token[:50]}...")
        print("\n" + "=" * 70)
        print("  ✅ 测试成功！")
        print("=" * 70 + "\n")
    except Exception as e:
        print(f"\n❌ 测试失败: {e}")
        print("\n请检查配置：")
        print(f"  • WORKER_URL: {WORKER_URL}")
        print(f"  • EMAIL_DOMAIN: {EMAIL_DOMAIN}")
        print(f"  • ADMIN_PASSWORD: {'已设置' if ADMIN_PASSWORD != 'your_admin_password' else '⚠️  未设置'}\n")
