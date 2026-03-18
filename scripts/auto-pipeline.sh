#!/bin/bash
# ============================================================
# auto-pipeline.sh — 全自动化流水线
# 注册 Cursor 账号 → 提取 Token → 注入 cursor-api → 验证 API
# ============================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step()  { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"; }

# ----------------------------------------------------------
# 配置
# ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# 加载 .env（如果存在）
[ -f "${PROJECT_DIR}/.env" ] && set -a && source "${PROJECT_DIR}/.env" && set +a

# 服务地址
REGISTER_API="${REGISTER_API:-http://127.0.0.1:9010}"
CURSOR_API="${CURSOR_API:-http://127.0.0.1:9002}"
NEW_API="${NEW_API:-http://127.0.0.1:3000}"
CURSOR_API_AUTH="${CURSOR_API_AUTH_TOKEN}"

# 注册数量
REGISTER_COUNT="${1:-3}"  # 默认注册 3 个账号

echo -e "${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   Cursor 全自动化注册 → API 验证流水线   ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ----------------------------------------------------------
# Step 1: 检查前置服务
# ----------------------------------------------------------
step "Step 1/5: 检查前置服务状态"

check_service() {
    local name=$1
    local url=$2
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" "${url}" --max-time 5 2>/dev/null || echo "000")
    if [ "${response}" != "000" ]; then
        info "  ✓ ${name} 正常 (HTTP ${response})"
        return 0
    else
        error "  ✗ ${name} 不可达 (${url})"
        return 1
    fi
}

SERVICES_OK=true
check_service "cursor-register"   "${REGISTER_API}/health"  || SERVICES_OK=false
check_service "cursor-api"        "${CURSOR_API}/v1/models"  || SERVICES_OK=false

if [ "${SERVICES_OK}" = "false" ]; then
    error "部分服务不可用，请先启动所有服务:"
    error "  cd ${PROJECT_DIR} && docker compose -f docker-compose.reverse.yml up -d"
    exit 1
fi

# ----------------------------------------------------------
# Step 2: 触发自动注册
# ----------------------------------------------------------
step "Step 2/5: 触发 Cursor 账号自动注册"

# 检查当前注册状态
STATUS=$(curl -s "${REGISTER_API}/registration/status" 2>/dev/null)
CURRENT_COUNT=$(echo "${STATUS}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('current_count',0))" 2>/dev/null || echo "0")

info "当前已注册账号数: ${CURRENT_COUNT}"

# 设置目标账号数
TARGET=$((CURRENT_COUNT + REGISTER_COUNT))
info "目标账号数: ${TARGET}"

# 更新最大账号数配置
curl -s -X POST "${REGISTER_API}/config" \
    -H "Content-Type: application/json" \
    -d "{\"max_accounts\": ${TARGET}}" > /dev/null 2>&1

# 启动注册
info "正在启动自动注册（目标 +${REGISTER_COUNT} 个账号）..."
RESULT=$(curl -s "${REGISTER_API}/registration/start" 2>/dev/null)
IS_RUNNING=$(echo "${RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',{}).get('is_running',False))" 2>/dev/null || echo "False")

if [ "${IS_RUNNING}" = "True" ] || [ "${IS_RUNNING}" = "true" ]; then
    info "注册任务已启动"
else
    warn "注册任务启动响应: ${RESULT}"
fi

# ----------------------------------------------------------
# Step 3: 等待注册完成
# ----------------------------------------------------------
step "Step 3/5: 等待注册完成"

MAX_WAIT=600  # 最长等待 10 分钟
POLL_INTERVAL=15
ELAPSED=0

while [ ${ELAPSED} -lt ${MAX_WAIT} ]; do
    STATUS=$(curl -s "${REGISTER_API}/registration/status" 2>/dev/null)
    CURRENT=$(echo "${STATUS}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('current_count',0))" 2>/dev/null || echo "0")
    TASK_STATUS=$(echo "${STATUS}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task_status','unknown'))" 2>/dev/null || echo "unknown")

    echo -e "\r${YELLOW}  等待中... ${ELAPSED}/${MAX_WAIT}s | 已注册: ${CURRENT}/${TARGET} | 状态: ${TASK_STATUS}${NC}\c"

    if [ "${CURRENT}" -ge "${TARGET}" ] 2>/dev/null; then
        echo ""
        info "注册完成！已注册 ${CURRENT} 个账号"
        break
    fi

    if [ "${TASK_STATUS}" = "stopped" ] || [ "${TASK_STATUS}" = "error" ]; then
        echo ""
        warn "注册任务已停止 (状态: ${TASK_STATUS})"
        break
    fi

    sleep ${POLL_INTERVAL}
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ ${ELAPSED} -ge ${MAX_WAIT} ]; then
    echo ""
    warn "等待超时（${MAX_WAIT}秒），将使用当前已注册的账号继续"
fi

# ----------------------------------------------------------
# Step 4: 推送 Token 到 cursor-api
# ----------------------------------------------------------
step "Step 4/5: 推送 Token 到 cursor-api"

export REGISTER_API
export CURSOR_API
export CURSOR_API_AUTH

if [ -f "${SCRIPT_DIR}/feed-tokens.sh" ]; then
    bash "${SCRIPT_DIR}/feed-tokens.sh"
else
    error "未找到 feed-tokens.sh 脚本"
    exit 1
fi

# ----------------------------------------------------------
# Step 5: 验证 API 可用性
# ----------------------------------------------------------
step "Step 5/5: 验证 API 可用性"

info "正在测试 cursor-api /v1/chat/completions ..."

TEST_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "${CURSOR_API}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${CURSOR_API_AUTH}" \
    -d '{
        "model": "claude-3.5-sonnet",
        "messages": [{"role": "user", "content": "Say hi in one word"}],
        "max_tokens": 10,
        "stream": false
    }' --max-time 30 2>/dev/null)

HTTP_CODE=$(echo "${TEST_RESPONSE}" | tail -1)
BODY=$(echo "${TEST_RESPONSE}" | head -n -1)

if [ "${HTTP_CODE}" = "200" ]; then
    info "  ✓ API 调用成功！(HTTP 200)"
    CONTENT=$(echo "${BODY}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
choices = data.get('choices', [])
if choices:
    msg = choices[0].get('message', {}).get('content', 'N/A')
    print(msg[:100])
else:
    print('(无内容)')
" 2>/dev/null || echo "(解析失败)")
    info "  模型回复: ${CONTENT}"
else
    warn "  API 测试返回 HTTP ${HTTP_CODE}"
    warn "  响应: ${BODY:0:200}"
    warn "  这可能是因为 Token 尚未生效，请稍后重试"
fi

# ----------------------------------------------------------
# 最终汇总
# ----------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║          全自动化流水线执行完毕          ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}服务端点:${NC}"
echo -e "    注册管理: ${CYAN}${REGISTER_API}${NC}"
echo -e "    Cursor API: ${CYAN}${CURSOR_API}${NC}"
echo -e "    New API: ${CYAN}${NEW_API}${NC}"
echo ""
echo -e "  ${BOLD}后续操作:${NC}"
echo -e "    1. 在 New API 添加渠道 → 类型: OpenAI → 基地址: http://cursor-api:3000"
echo -e "    2. 创建令牌 → 分发给用户使用"
echo -e "    3. 定期运行此脚本补充新账号"
echo ""
