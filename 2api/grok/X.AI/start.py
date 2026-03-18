#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
简单启动脚本 - 使用 DrissionPage 自动注册
"""

from DrissionPage_example import run_single_registration
import sys

def main():
    print("\n" + "=" * 70)
    print("  🚀 X.AI 自动注册工具 - by 凉心ovo")
    print("=" * 70)
    
    try:
        # 执行单次注册
        run_single_registration(
            output_path="sso.txt",
            extract_numbers=False
        )
        
        print("\n" + "=" * 70)
        print("  ✅ 注册成功！")
        print("  📁 SSO Cookie 已保存到: sso.txt")
        print("=" * 70 + "\n")
        return 0
        
    except KeyboardInterrupt:
        print("\n\n" + "=" * 70)
        print("  ⚠️  用户中断操作")
        print("=" * 70 + "\n")
        return 1
        
    except Exception as e:
        print("\n" + "=" * 70)
        print(f"  ❌ 注册失败: {e}")
        print("=" * 70 + "\n")
        return 1

if __name__ == "__main__":
    sys.exit(main())
