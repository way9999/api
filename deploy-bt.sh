#!/bin/bash
# ============================================================
# 渡屿AI Gateway — 宝塔面板一键部署脚本
# 用法: bash deploy-bt.sh
# ============================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }
step()  { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"; }

echo -e "${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   渡屿AI Gateway — 宝塔面板部署工具      ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"

# 检查 root
[[ $EUID -ne 0 ]] && error "请以 root 用户运行: sudo bash deploy-bt.sh"

# 项目目录
PROJECT_DIR="/opt/api"

# ----------------------------------------------------------
# 1. 安装 Docker
# ----------------------------------------------------------
step "1/7 检查 Docker"

if command -v docker &>/dev/null && docker info &>/dev/null; then
    info "Docker 已就绪: $(docker --version)"
else
    warn "Docker 未安装，正在安装..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    info "Docker 安装完成"
fi

# 检查 Docker Compose
if docker compose version &>/dev/null; then
    info "Docker Compose 已就绪"
else
    warn "安装 Docker Compose 插件..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq docker-compose-plugin
    elif command -v yum &>/dev/null; then
        yum install -y docker-compose-plugin
    fi
    docker compose version &>/dev/null || error "Docker Compose 安装失败"
    info "Docker Compose 安装完成"
fi

# ----------------------------------------------------------
# 2. Clone 项目
# ----------------------------------------------------------
step "2/7 获取项目代码"

if [[ -d "${PROJECT_DIR}/.git" ]]; then
    info "项目已存在，拉取最新代码..."
    cd "${PROJECT_DIR}"
    git pull || warn "git pull 失败，使用现有代码继续"
else
    # 安装 git
    if ! command -v git &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq git
        elif command -v yum &>/dev/null; then
            yum install -y git
        fi
    fi

    if [[ -d "${PROJECT_DIR}" ]]; then
        warn "${PROJECT_DIR} 已存在但不是 git 仓库，备份后重新 clone..."
        mv "${PROJECT_DIR}" "${PROJECT_DIR}.bak.$(date +%s)"
    fi

    git clone https://github.com/way9999/api.git "${PROJECT_DIR}"
    cd "${PROJECT_DIR}"
    info "项目已 clone 到 ${PROJECT_DIR}"
fi

cd "${PROJECT_DIR}"

# ----------------------------------------------------------
# 3. 配置 .env
# ----------------------------------------------------------
step "3/7 配置环境变量"

if [[ -f ".env" ]]; then
    info ".env 已存在，跳过生成"
else
    if [[ -f "config/env.example" ]]; then
        cp config/env.example .env
        info "已从 env.example 生成 .env"

        # 生成随机密钥
        MYSQL_PW=$(openssl rand -hex 16)
        SESSION=$(openssl rand -hex 32)
        TOKEN=$(openssl rand -hex 20)
        ANTI_KEY="sk-$(openssl rand -hex 16)"
        CURSOR_KEY=$(openssl rand -hex 16)
        KIRO_KEY=$(openssl rand -hex 16)
        RESIN_ADMIN=$(openssl rand -hex 16)
        RESIN_PROXY=$(openssl rand -hex 16)

        sed -i "s|your_mysql_password_here|${MYSQL_PW}|" .env
        sed -i "s|your_session_secret_here|${SESSION}|" .env
        sed -i "s|your_root_token_here|${TOKEN}|" .env
        sed -i "s|sk-your_antigravity_key_here|${ANTI_KEY}|" .env
        sed -i "s|your_cursor_api_auth_token_here|${CURSOR_KEY}|" .env
        sed -i "s|your_kiro2api_key_here|${KIRO_KEY}|" .env

        info "密钥已自动生成"
    else
        error "config/env.example 不存在，无法生成 .env"
    fi
fi

# 确保有域名变量
if ! grep -q "^MAIN_DOMAIN=" .env 2>/dev/null; then
    cat >> .env << 'EOF'

# --- 域名配置（Caddy 使用） ---
MAIN_DOMAIN=localhost
REGISTER_DOMAIN=
# --- Cloudflare Tunnel Token（可选） ---
CF_TUNNEL_TOKEN=
EOF
    info "已追加域名配置到 .env"
fi

# 交互式配置域名
echo ""
echo -e "${BOLD}请输入域名配置:${NC}"
echo -n -e "${CYAN}主域名 (如 chat.example.com，直接回车用 localhost): ${NC}"
read -r INPUT_DOMAIN
INPUT_DOMAIN=${INPUT_DOMAIN:-localhost}
sed -i "s|^MAIN_DOMAIN=.*|MAIN_DOMAIN=${INPUT_DOMAIN}|" .env

if [[ "${INPUT_DOMAIN}" != "localhost" ]]; then
    echo -n -e "${CYAN}注册域名 (如 register.example.com，留空跳过): ${NC}"
    read -r INPUT_REG_DOMAIN
    if [[ -n "${INPUT_REG_DOMAIN}" ]]; then
        sed -i "s|^REGISTER_DOMAIN=.*|REGISTER_DOMAIN=${INPUT_REG_DOMAIN}|" .env
    fi
fi

info "域名已配置: ${INPUT_DOMAIN}"

# ----------------------------------------------------------
# 4. 创建数据目录
# ----------------------------------------------------------
step "4/7 创建数据目录"

dirs=(
    data/antigravity
    data/cliproxyapi/auth
    data/cliproxyapi/data
    data/cursor-api
    data/cursor-register
    data/gpt-register/output
    data/kirocli2api
    data/copilot-api
    data/resin/cache
    data/resin/state
    data/resin/log
)
for d in "${dirs[@]}"; do
    mkdir -p "$d"
done
info "数据目录已就绪"

# ----------------------------------------------------------
# 5. 构建本地镜像
# ----------------------------------------------------------
step "5/7 构建本地镜像"

info "构建逆向代理层镜像..."
docker compose -f docker-compose.reverse.yml build --parallel 2>&1 | tail -3 || warn "部分镜像构建失败"

info "构建 Caddy 自定义镜像..."
docker compose -f docker-compose.caddy.yml build 2>&1 | tail -3 || warn "Caddy 镜像构建失败"

# ----------------------------------------------------------
# 6. 启动服务
# ----------------------------------------------------------
step "6/7 启动服务"

# 选择 Caddyfile
if [[ "${INPUT_DOMAIN}" == "localhost" ]]; then
    cp Caddyfile.local Caddyfile.active 2>/dev/null
    info "使用本地模式 Caddyfile"
else
    cp Caddyfile Caddyfile.active 2>/dev/null
    info "使用生产模式 Caddyfile（自动 HTTPS）"
fi

info "启动核心服务（MySQL + Redis + New API）..."
docker compose -f docker-compose.yml up -d

info "等待 MySQL 就绪..."
for i in $(seq 1 24); do
    if docker inspect --format='{{.State.Health.Status}}' api-mysql 2>/dev/null | grep -q healthy; then
        info "MySQL 已就绪"
        break
    fi
    [[ $i -eq 24 ]] && warn "MySQL 健康检查超时，继续部署..."
    sleep 5
done

info "启动逆向代理层..."
docker compose -f docker-compose.reverse.yml up -d

info "启动 Caddy 反向代理..."
docker compose -f docker-compose.caddy.yml up -d

# 检查是否需要启动 Tunnel
CF_TOKEN=$(grep "^CF_TUNNEL_TOKEN=" .env | cut -d'=' -f2-)
if [[ -n "${CF_TOKEN}" ]]; then
    info "启动 Cloudflare Tunnel..."
    docker compose -f docker-compose.tunnel.yml up -d
fi

# ----------------------------------------------------------
# 7. 部署完成
# ----------------------------------------------------------
step "7/7 部署完成"

sleep 5

echo ""
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
echo ""

PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "<服务器IP>")

echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  部署成功！${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo ""
if [[ "${INPUT_DOMAIN}" == "localhost" ]]; then
    echo -e "  管理面板:  ${CYAN}http://${PUBLIC_IP}${NC}"
    echo -e "  Chat UI:   ${CYAN}http://${PUBLIC_IP}/chat/${NC}"
    echo -e "  API 端点:  ${CYAN}http://${PUBLIC_IP}/v1/${NC}"
else
    echo -e "  管理面板:  ${CYAN}https://${INPUT_DOMAIN}${NC}"
    echo -e "  Chat UI:   ${CYAN}https://${INPUT_DOMAIN}/chat/${NC}"
    echo -e "  API 端点:  ${CYAN}https://${INPUT_DOMAIN}/v1/${NC}"
    echo -e "  Resin:     ${CYAN}https://${INPUT_DOMAIN}/resin/${NC}"
    if [[ -n "${INPUT_REG_DOMAIN}" ]]; then
        echo -e "  注册面板:  ${CYAN}https://${INPUT_REG_DOMAIN}${NC}"
    fi
fi
echo ""
echo -e "  默认账号:  ${CYAN}root${NC} / ${CYAN}123456${NC} ${RED}(请立即修改！)${NC}"
echo -e "  Root Token: ${CYAN}$(grep '^INITIAL_ROOT_TOKEN=' .env | cut -d'=' -f2-)${NC}"
echo ""
echo -e "  ${BOLD}管理命令:${NC}"
echo -e "  cd ${PROJECT_DIR}"
echo -e "  docker compose ps                    # 查看状态"
echo -e "  docker compose logs -f new-api       # 查看日志"
echo -e "  docker compose -f docker-compose.caddy.yml logs caddy  # Caddy 日志"
echo ""
echo -e "  ${YELLOW}请确保域名 DNS 已解析到 ${PUBLIC_IP}${NC}"
echo -e "  ${YELLOW}请在宝塔面板防火墙中放行 80 和 443 端口${NC}"
echo ""
