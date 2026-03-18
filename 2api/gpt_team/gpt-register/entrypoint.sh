#!/bin/bash
set -e

echo "=== GPT 注册机 + 自动注入 CLIProxyAPI ==="
echo "代理: ${PROXY_URL:-无}"
echo "线程数: ${THREADS:-3}"
echo "Auth 目录: ${AUTH_DIR:-/auth}"
echo "输出目录: ${OUTPUT_DIR:-/app/output}"
echo ""

# 模式选择
case "${MODE:-register}" in
  register)
    echo "[*] 启动注册模式（HTTP API 注册 + 自动注入）"
    exec python -u register.py \
      ${PROXY_URL:+--proxy "$PROXY_URL"} \
      ${ONCE:+--once}
    ;;
  browser)
    echo "[*] 启动浏览器注册模式（Playwright + LLM 自动化）"
    exec python -u register_browser.py \
      ${PROXY_URL:+--proxy "$PROXY_URL"} \
      ${ONCE:+--once}
    ;;
  inject)
    echo "[*] 启动注入模式（仅扫描 output 目录并注入）"
    exec python -u inject.py
    ;;
  watch)
    echo "[*] 启动监控模式（持续扫描并注入新 token）"
    exec python -u inject.py --watch
    ;;
  dashboard)
    echo "[*] 启动 Dashboard 模式（Web 管理面板 :9005）"
    exec python -u dashboard.py
    ;;
  *)
    echo "[Error] 未知模式: $MODE"
    echo "可用模式: register, browser, inject, watch, dashboard"
    exit 1
    ;;
esac
