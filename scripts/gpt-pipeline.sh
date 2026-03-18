#!/bin/bash
# ============================================================
# gpt-pipeline.sh — GPT 注册 + 注入 + CLIProxyAPI 一键流程
# 用法:
#   bash scripts/gpt-pipeline.sh              # 持续注册模式
#   bash scripts/gpt-pipeline.sh --once       # 只跑一轮
#   bash scripts/gpt-pipeline.sh --inject     # 仅注入已有 token
#   bash scripts/gpt-pipeline.sh --status     # 查看状态
#   bash scripts/gpt-pipeline.sh --stop       # 停止注册机
# ============================================================

set -e
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f docker-compose.reverse.yml"
COMPOSE_TOOLS="$COMPOSE --profile tools"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[*]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }

# 确保 resin 和 cliproxyapi 在运行
ensure_deps() {
    info "检查依赖服务..."

    if ! docker ps --format '{{.Names}}' | grep -q '^resin$'; then
        warn "resin 未运行，正在启动..."
        $COMPOSE up -d resin
        sleep 3
    fi

    if ! docker ps --format '{{.Names}}' | grep -q '^cliproxyapi$'; then
        warn "cliproxyapi 未运行，正在启动..."
        $COMPOSE up -d cliproxyapi
        sleep 3
    fi

    info "依赖服务就绪"
}

# 构建注册机镜像
build() {
    info "构建 GPT 注册机镜像..."
    $COMPOSE_TOOLS build gpt-register
    info "镜像构建完成"
}

# 启动注册（持续模式）
start_register() {
    ensure_deps
    build

    info "启动 GPT 注册机（持续模式）..."
    GPT_REGISTER_MODE=register GPT_REGISTER_ONCE= \
        $COMPOSE_TOOLS up -d gpt-register

    info "注册机已在后台运行"
    info "查看日志: docker compose -f docker-compose.reverse.yml --profile tools logs -f gpt-register"
    info "查看注入结果: ls -la data/cliproxyapi/auth/codex-*.json"
}

# 启动注册（单次模式）
start_once() {
    ensure_deps
    build

    info "启动 GPT 注册机（单次模式）..."
    GPT_REGISTER_MODE=register GPT_REGISTER_ONCE=1 \
        $COMPOSE_TOOLS run --rm gpt-register

    info "单次注册完成"
    show_result
}

# 仅注入已有 token
inject_only() {
    info "扫描并注入已有 token..."
    $COMPOSE_TOOLS run --rm -e MODE=inject gpt-register
    show_result
}

# 查看状态
show_status() {
    echo ""
    info "=== GPT 注册机状态 ==="

    if docker ps --format '{{.Names}}' | grep -q '^gpt-register$'; then
        echo -e "  注册机: ${GREEN}运行中${NC}"
    else
        echo -e "  注册机: ${YELLOW}未运行${NC}"
    fi

    # 统计 token 数量
    local token_count=$(ls data/gpt-register/output/token_*.json 2>/dev/null | wc -l)
    local auth_count=$(ls data/cliproxyapi/auth/codex-*.json 2>/dev/null | wc -l)
    echo "  已注册 token: $token_count"
    echo "  已注入 CLIProxyAPI: $auth_count"

    if [ -f data/gpt-register/output/accounts.txt ]; then
        local account_count=$(wc -l < data/gpt-register/output/accounts.txt)
        echo "  accounts.txt 记录: $account_count"
    fi

    echo ""

    if docker ps --format '{{.Names}}' | grep -q '^cliproxyapi$'; then
        echo -e "  CLIProxyAPI: ${GREEN}运行中${NC} (127.0.0.1:9001)"
    else
        echo -e "  CLIProxyAPI: ${RED}未运行${NC}"
    fi

    echo ""
}

# 显示注入结果
show_result() {
    local auth_count=$(ls data/cliproxyapi/auth/codex-*.json 2>/dev/null | wc -l)
    info "CLIProxyAPI auth 目录中共 $auth_count 个 Codex 凭据"

    if [ "$auth_count" -gt 0 ]; then
        info "最新注入的凭据:"
        ls -lt data/cliproxyapi/auth/codex-*.json 2>/dev/null | head -5
    fi
}

# 停止注册机
stop() {
    info "停止 GPT 注册机..."
    $COMPOSE_TOOLS stop gpt-register 2>/dev/null || true
    $COMPOSE_TOOLS rm -f gpt-register 2>/dev/null || true
    info "已停止"
}

# 主入口
case "${1:-}" in
    --once|-1)
        start_once
        ;;
    --inject|-i)
        inject_only
        ;;
    --status|-s)
        show_status
        ;;
    --stop)
        stop
        ;;
    --build|-b)
        build
        ;;
    --help|-h)
        echo "用法: $0 [选项]"
        echo ""
        echo "选项:"
        echo "  (无参数)     持续注册模式（后台运行）"
        echo "  --once, -1   只跑一轮注册"
        echo "  --inject, -i 仅注入已有 token 到 CLIProxyAPI"
        echo "  --status, -s 查看注册机和注入状态"
        echo "  --stop       停止注册机"
        echo "  --build, -b  仅构建镜像"
        echo "  --help, -h   显示帮助"
        ;;
    *)
        start_register
        ;;
esac
