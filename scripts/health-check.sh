#!/bin/bash

# ============================================================
# 服务健康检查脚本
# 检查所有核心服务的运行状态，异常时输出红色警告
# 可选：服务异常时发送 Webhook 通知
# ============================================================

# ---------- 颜色定义 ----------

# 绿色：服务正常
GREEN='\033[0;32m'
# 红色：服务异常
RED='\033[0;31m'
# 黄色：警告信息
YELLOW='\033[0;33m'
# 青色：标题信息
CYAN='\033[0;36m'
# 重置颜色
NC='\033[0m'

# ---------- 全局变量 ----------

# 检查失败计数器，任何服务异常都会递增
FAIL_COUNT=0

# 失败服务名称列表，用于通知
FAILED_SERVICES=""

# HTTP 请求超时时间（秒）
CURL_TIMEOUT=5

# ---------- Webhook 通知配置（占位符，按需填写） ----------

# 启用/禁用 Webhook 通知（设为 true 启用）
WEBHOOK_ENABLED=false

# Webhook 地址（支持钉钉、飞书、企业微信、Slack 等）
WEBHOOK_URL="https://your-webhook-url-here"

# ---------- 辅助函数 ----------

# 输出分隔线
print_separator() {
    echo -e "${CYAN}--------------------------------------------------${NC}"
}

# 检查结果输出：成功
print_ok() {
    local service_name="$1"
    local detail="$2"
    echo -e "  ${GREEN}[OK]${NC}   ${service_name} ${detail}"
}

# 检查结果输出：失败
print_fail() {
    local service_name="$1"
    local detail="$2"
    echo -e "  ${RED}[FAIL]${NC} ${service_name} ${detail}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    # 记录失败的服务名称
    if [ -z "${FAILED_SERVICES}" ]; then
        FAILED_SERVICES="${service_name}"
    else
        FAILED_SERVICES="${FAILED_SERVICES}, ${service_name}"
    fi
}

# 检查结果输出：警告
print_warn() {
    local service_name="$1"
    local detail="$2"
    echo -e "  ${YELLOW}[WARN]${NC} ${service_name} ${detail}"
}

# ---------- 开始健康检查 ----------

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}       服务健康检查 - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# ---------- 1. 检查 New API 服务 ----------

print_separator
echo -e "${CYAN}[1/11] 检查 New API 服务 (端口 3000)${NC}"

# 通过 /api/status 接口检查 New API 是否正常响应
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time ${CURL_TIMEOUT} http://127.0.0.1:3000/api/status 2>/dev/null)

if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 400 ] 2>/dev/null; then
    print_ok "New API" "- HTTP 状态码: ${HTTP_CODE}"
else
    print_fail "New API" "- 无法访问 http://127.0.0.1:3000/api/status (HTTP: ${HTTP_CODE:-无响应})"
fi

# ---------- 2. 检查 Antigravity Manager 服务 ----------

print_separator
echo -e "${CYAN}[2/11] 检查 Antigravity Manager 服务 (端口 9000)${NC}"

# Antigravity 多账号管理代理，Web 管理后台 + API
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time ${CURL_TIMEOUT} http://127.0.0.1:9000/ 2>/dev/null)

if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 400 ] 2>/dev/null; then
    print_ok "Antigravity Manager" "- Web 面板正常 (HTTP: ${HTTP_CODE})"
else
    if ss -tlnp 2>/dev/null | grep -q ':9000 ' || netstat -tlnp 2>/dev/null | grep -q ':9000 '; then
        print_warn "Antigravity Manager" "- 端口 9000 在监听，但 Web 面板无响应 (HTTP: ${HTTP_CODE:-无响应})"
    else
        print_fail "Antigravity Manager" "- 端口 9000 未监听，服务可能未启动"
    fi
fi

# ---------- 3. 检查 CLIProxyAPI 服务 ----------

print_separator
echo -e "${CYAN}[3/11] 检查 CLIProxyAPI 服务 (端口 9001)${NC}"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time ${CURL_TIMEOUT} http://127.0.0.1:9001/health 2>/dev/null)

if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 400 ] 2>/dev/null; then
    print_ok "CLIProxyAPI" "- /health 端点正常 (HTTP: ${HTTP_CODE})"
else
    if ss -tlnp 2>/dev/null | grep -q ':9001 ' || netstat -tlnp 2>/dev/null | grep -q ':9001 '; then
        print_warn "CLIProxyAPI" "- 端口 9001 在监听，但 /health 端点无响应 (HTTP: ${HTTP_CODE:-无响应})"
    else
        print_fail "CLIProxyAPI" "- 端口 9001 未监听，服务可能未启动"
    fi
fi

# ---------- 4. 检查 WARP Proxy 服务 ----------

print_separator
echo -e "${CYAN}[4/11] 检查 WARP Proxy 服务 (端口 1080)${NC}"

WARP_RESULT=$(curl -s --socks5 127.0.0.1:1080 --max-time ${CURL_TIMEOUT} https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)

if echo "${WARP_RESULT}" | grep -qE "warp=(on|plus)"; then
    WARP_STATUS=$(echo "${WARP_RESULT}" | grep "warp=" | head -1)
    print_ok "WARP Proxy" "- ${WARP_STATUS}"
else
    if ss -tlnp 2>/dev/null | grep -q ':1080 ' || netstat -tlnp 2>/dev/null | grep -q ':1080 '; then
        print_warn "WARP Proxy" "- 端口 1080 在监听，但 WARP 状态异常"
    else
        print_fail "WARP Proxy" "- 端口 1080 未监听，服务可能未启动"
    fi
fi

# ---------- 5. 检查 Cursor API 服务 ----------

print_separator
echo -e "${CYAN}[5/11] 检查 Cursor API 服务 (端口 9002)${NC}"

# wisdgod/cursor-api，Rust 编写，Web 管理前端 + OpenAI 兼容 API
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time ${CURL_TIMEOUT} http://127.0.0.1:9002/ 2>/dev/null)

if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 400 ] 2>/dev/null; then
    print_ok "Cursor API" "- 服务正常 (HTTP: ${HTTP_CODE})"
else
    if ss -tlnp 2>/dev/null | grep -q ':9002 ' || netstat -tlnp 2>/dev/null | grep -q ':9002 '; then
        print_warn "Cursor API" "- 端口 9002 在监听，但无响应 (HTTP: ${HTTP_CODE:-无响应})"
    else
        print_fail "Cursor API" "- 端口 9002 未监听，服务可能未启动"
    fi
fi

# ---------- 6. 检查 Kiro2API 服务 ----------

print_separator
echo -e "${CYAN}[6/11] 检查 Kiro2API 服务 (端口 9003)${NC}"

# caidaoli/kiro2api，Go 编写，/v1/models 作为健康检查端点
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time ${CURL_TIMEOUT} http://127.0.0.1:9003/v1/models 2>/dev/null)

if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 400 ] 2>/dev/null; then
    print_ok "Kiro2API" "- /v1/models 端点正常 (HTTP: ${HTTP_CODE})"
else
    if ss -tlnp 2>/dev/null | grep -q ':9003 ' || netstat -tlnp 2>/dev/null | grep -q ':9003 '; then
        print_warn "Kiro2API" "- 端口 9003 在监听，但 /v1/models 端点无响应 (HTTP: ${HTTP_CODE:-无响应})"
    else
        print_fail "Kiro2API" "- 端口 9003 未监听，服务可能未启动"
    fi
fi

# ---------- 7. 检查 Copilot API 服务 ----------

print_separator
echo -e "${CYAN}[7/11] 检查 Copilot API 服务 (端口 9008)${NC}"

# ericc-ch/copilot-api，健康检查通过根路径
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time ${CURL_TIMEOUT} http://127.0.0.1:9008/ 2>/dev/null)

if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 400 ] 2>/dev/null; then
    print_ok "Copilot API" "- 服务正常 (HTTP: ${HTTP_CODE})"
else
    if ss -tlnp 2>/dev/null | grep -q ':9008 ' || netstat -tlnp 2>/dev/null | grep -q ':9008 '; then
        print_warn "Copilot API" "- 端口 9008 在监听，但无响应 (HTTP: ${HTTP_CODE:-无响应})"
    else
        print_fail "Copilot API" "- 端口 9008 未监听，服务可能未启动"
    fi
fi

# ---------- 8. 检查 Cursor Register 服务 ----------

print_separator
echo -e "${CYAN}[8/11] 检查 Cursor Register 服务 (端口 9010)${NC}"

# cursor-auto-register，自动注册 + Token 管理
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time ${CURL_TIMEOUT} http://127.0.0.1:9010/health 2>/dev/null)

if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 400 ] 2>/dev/null; then
    # 获取已注册账号数
    ACCOUNT_COUNT=$(curl -s --max-time ${CURL_TIMEOUT} http://127.0.0.1:9010/registration/status 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('current_count','?'))" 2>/dev/null || echo "?")
    print_ok "Cursor Register" "- /health 正常 (HTTP: ${HTTP_CODE}, 账号: ${ACCOUNT_COUNT})"
else
    if ss -tlnp 2>/dev/null | grep -q ':9010 ' || netstat -tlnp 2>/dev/null | grep -q ':9010 '; then
        print_warn "Cursor Register" "- 端口 9010 在监听，但 /health 端点无响应 (HTTP: ${HTTP_CODE:-无响应})"
    else
        print_warn "Cursor Register" "- 端口 9010 未监听（可选服务，不影响核心功能）"
    fi
fi

# ---------- 9. 检查 MySQL 服务 ----------

print_separator
echo -e "${CYAN}[9/11] 检查 MySQL 服务${NC}"

MYSQL_PING=$(docker exec api-mysql mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD:-root}" 2>/dev/null)

if echo "${MYSQL_PING}" | grep -q "alive"; then
    print_ok "MySQL" "- mysqld is alive"
else
    CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' api-mysql 2>/dev/null)
    if [ -n "${CONTAINER_STATUS}" ]; then
        print_fail "MySQL" "- 容器状态: ${CONTAINER_STATUS}，ping 失败"
    else
        print_fail "MySQL" "- 容器不存在或 Docker 未运行"
    fi
fi

# ---------- 10. 检查 Redis 服务 ----------

print_separator
echo -e "${CYAN}[10/11] 检查 Redis 服务${NC}"

REDIS_PING=$(docker exec api-redis redis-cli ping 2>/dev/null)

if [ "${REDIS_PING}" = "PONG" ]; then
    print_ok "Redis" "- PONG 响应正常"
else
    CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' api-redis 2>/dev/null)
    if [ -n "${CONTAINER_STATUS}" ]; then
        print_fail "Redis" "- 容器状态: ${CONTAINER_STATUS}，ping 失败"
    else
        print_fail "Redis" "- 容器不存在或 Docker 未运行"
    fi
fi

# ---------- 11. 检查 Nginx 服务 ----------

print_separator
echo -e "${CYAN}[11/11] 检查 Nginx 服务${NC}"

if systemctl is-active --quiet nginx 2>/dev/null; then
    print_ok "Nginx" "- systemctl 状态: active"
else
    if pgrep -x nginx > /dev/null 2>&1; then
        print_ok "Nginx" "- 进程运行中（非 systemctl 管理）"
    else
        print_fail "Nginx" "- 服务未运行"
    fi
fi

# ---------- 检查结果汇总 ----------

echo ""
print_separator
echo ""

if [ ${FAIL_COUNT} -eq 0 ]; then
    echo -e "${GREEN}所有服务运行正常！ (11/11)${NC}"
else
    echo -e "${RED}检测到 ${FAIL_COUNT} 个服务异常！${NC}"
    echo -e "${RED}异常服务: ${FAILED_SERVICES}${NC}"
fi

echo ""

# ---------- Webhook 通知（服务异常时触发） ----------

if [ ${FAIL_COUNT} -gt 0 ] && [ "${WEBHOOK_ENABLED}" = "true" ]; then
    NOTIFY_TITLE="[告警] 服务健康检查失败"
    NOTIFY_BODY="检测时间: $(date '+%Y-%m-%d %H:%M:%S')\n异常服务: ${FAILED_SERVICES}\n异常数量: ${FAIL_COUNT} 个\n主机名: $(hostname)"

    PAYLOAD=$(cat <<EOF
{
    "msgtype": "text",
    "text": {
        "content": "${NOTIFY_TITLE}\n${NOTIFY_BODY}"
    }
}
EOF
)

    NOTIFY_RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}" \
        "${WEBHOOK_URL}" 2>/dev/null)

    if [ "${NOTIFY_RESULT}" -ge 200 ] && [ "${NOTIFY_RESULT}" -lt 300 ] 2>/dev/null; then
        echo -e "${YELLOW}告警通知已发送 (HTTP: ${NOTIFY_RESULT})${NC}"
    else
        echo -e "${RED}告警通知发送失败 (HTTP: ${NOTIFY_RESULT:-无响应})${NC}"
    fi
elif [ ${FAIL_COUNT} -gt 0 ] && [ "${WEBHOOK_ENABLED}" != "true" ]; then
    echo -e "${YELLOW}提示: Webhook 通知未启用。如需开启，请将脚本中 WEBHOOK_ENABLED 设为 true 并配置 WEBHOOK_URL${NC}"
fi

echo ""

# ---------- 返回退出码 ----------

if [ ${FAIL_COUNT} -gt 0 ]; then
    exit 1
fi

exit 0
