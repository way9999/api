#!/bin/bash
# ============================================================
# feed-tokens.sh — 从 cursor-auto-register 提取 Token 注入 cursor-api
# 用途：将注册好的 Cursor 账号 Token 批量推送到 wisdgod/cursor-api
# ============================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ----------------------------------------------------------
# 配置（可通过环境变量覆盖）
# ----------------------------------------------------------
# cursor-auto-register API 地址
REGISTER_API="${REGISTER_API:-http://127.0.0.1:9010}"
# cursor-api (wisdgod) API 地址
CURSOR_API="${CURSOR_API:-http://127.0.0.1:9002}"
# cursor-api 鉴权 Token
CURSOR_API_AUTH="${CURSOR_API_AUTH:-${CURSOR_API_AUTH_TOKEN}}"

# ----------------------------------------------------------
# 1. 从 cursor-auto-register 导出所有账号
# ----------------------------------------------------------
info "正在从 cursor-auto-register 获取账号列表..."

ACCOUNTS_JSON=$(curl -s "${REGISTER_API}/accounts/export" 2>/dev/null)

if [ -z "${ACCOUNTS_JSON}" ] || [ "${ACCOUNTS_JSON}" = "null" ]; then
    error "无法连接 cursor-auto-register API (${REGISTER_API})"
    error "请确认服务已启动: docker compose -f docker-compose.reverse.yml ps cursor-register"
    exit 1
fi

# 提取活跃账号数量
TOTAL=$(echo "${ACCOUNTS_JSON}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
accounts = data if isinstance(data, list) else data.get('accounts', data.get('data', []))
active = [a for a in accounts if a.get('status') == 'active' and a.get('token')]
print(len(active))
" 2>/dev/null || echo "0")

if [ "${TOTAL}" = "0" ]; then
    warn "没有找到活跃的 Cursor 账号"
    warn "请先运行注册流程: curl ${REGISTER_API}/registration/start"
    exit 0
fi

info "发现 ${TOTAL} 个活跃账号"

# ----------------------------------------------------------
# 2. 逐个推送 Token 到 cursor-api
# ----------------------------------------------------------
info "正在向 cursor-api 推送 Token..."

SUCCESS=0
FAIL=0
SKIP=0

# 提取所有 token 列表
TOKENS=$(echo "${ACCOUNTS_JSON}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
accounts = data if isinstance(data, list) else data.get('accounts', data.get('data', []))
for a in accounts:
    if a.get('status') == 'active' and a.get('token'):
        user = a.get('user', '')
        token = a.get('token', '')
        email = a.get('email', '')
        # cursor-api 需要的格式: user::token (WorkosCursorSessionToken)
        if user and token:
            print(f'{user}%3A%3A{token}|||{email}')
        elif token:
            print(f'{token}|||{email}')
" 2>/dev/null)

if [ -z "${TOKENS}" ]; then
    error "无法解析账号 Token 数据"
    exit 1
fi

while IFS= read -r line; do
    TOKEN_VALUE=$(echo "${line}" | cut -d'|||' -f1)
    EMAIL=$(echo "${line}" | cut -d'|||' -f2)

    if [ -z "${TOKEN_VALUE}" ]; then
        continue
    fi

    # 通过 cursor-api 的 /tokens API 添加 Token
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        "${CURSOR_API}/tokens" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${CURSOR_API_AUTH}" \
        -d "{\"token\": \"${TOKEN_VALUE}\"}" 2>/dev/null)

    HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
    BODY=$(echo "${RESPONSE}" | head -n -1)

    case "${HTTP_CODE}" in
        200|201)
            info "  ✓ ${EMAIL} → 推送成功"
            SUCCESS=$((SUCCESS + 1))
            ;;
        409)
            warn "  ○ ${EMAIL} → 已存在，跳过"
            SKIP=$((SKIP + 1))
            ;;
        *)
            error "  ✗ ${EMAIL} → 失败 (HTTP ${HTTP_CODE}): ${BODY}"
            FAIL=$((FAIL + 1))
            ;;
    esac
done <<< "${TOKENS}"

# ----------------------------------------------------------
# 3. 输出汇总
# ----------------------------------------------------------
echo ""
info "============================================"
info "  Token 推送完成"
info "============================================"
info "  成功: ${SUCCESS}"
info "  跳过: ${SKIP} (已存在)"
[ "${FAIL}" -gt 0 ] && error "  失败: ${FAIL}"
info "  总计: ${TOTAL}"
echo ""
info "现在可以通过 cursor-api 使用这些 Token 了"
info "测试: curl ${CURSOR_API}/v1/models -H 'Authorization: Bearer ${CURSOR_API_AUTH}'"
