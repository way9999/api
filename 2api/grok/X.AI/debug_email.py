#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
调试邮件 API - 查看邮件数据结构
"""

import requests
import json
from openai_register import get_email_and_token, WORKER_URL, SITE_PASSWORD

def main():
    print("\n" + "=" * 70)
    print("  🐛 邮件 API 调试工具")
    print("=" * 70 + "\n")
    
    # 创建邮箱
    print("📧 创建临时邮箱...", end=" ")
    email, token = get_email_and_token()
    print(f"✅ {email}\n")
    
    # 等待用户发送测试邮件
    print(f"📮 请向 {email} 发送一封测试邮件")
    print("   （可以包含验证码，例如: 123456 或 ABC-123）\n")
    input("按回车键继续查看邮件...")
    
    # 获取邮件
    print("\n📬 获取邮件列表...", end=" ")
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }
    if SITE_PASSWORD:
        headers['x-custom-auth'] = SITE_PASSWORD
    
    try:
        resp = requests.get(
            f"{WORKER_URL}/api/mails?limit=20&offset=0",
            headers=headers,
            timeout=15
        )
        
        if resp.status_code == 200:
            data = resp.json()
            print(f"✅ 成功\n")
            
            # 显示数据结构
            print("📊 数据结构:")
            print(json.dumps(data, indent=2, ensure_ascii=False)[:1000])
            
            # 分析邮件
            messages = data.get("results", []) if isinstance(data, dict) else data
            print(f"\n📨 邮件数量: {len(messages)}")
            
            if messages:
                print("\n📧 第一封邮件:")
                msg = messages[0]
                print(f"  From: {msg.get('message_from', 'N/A')}")
                print(f"  Subject: {msg.get('subject', 'N/A')}")
                print(f"  Content: {str(msg.get('raw', 'N/A'))[:200]}...")
            else:
                print("\n⚠️  没有收到邮件")
        else:
            print(f"❌ 失败 (状态码: {resp.status_code})")
            print(f"响应: {resp.text}")
    except Exception as e:
        print(f"❌ 失败: {e}")
    
    print("\n" + "=" * 70)
    print("  ✅ 调试完成")
    print("=" * 70 + "\n")

if __name__ == "__main__":
    main()
