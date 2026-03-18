#!/bin/bash
# ============================================================
# 渡屿AI Gateway — 宝塔面板一键部署脚本（精简版）
# 只部署：MySQL + Redis + New API + Resin + GPT Register
# 反代使用宝塔自带 Nginx
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
echo "  ║   精简模式：核心 + Resin + GPT Register  ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"

[[ $EUID -ne 0 ]] && error "请以 root 用户运行: sudo bash deploy-bt.sh"

PROJECT_DIR="/opt/api"

# ----------------------------------------------------------
# 1. 检查 Docker
# ----------------------------------------------------------
step "1/6 检查 Docker"

if command -v docker &>/dev/null && docker info &>/dev/null; then
    info "Docker 已就绪: $(docker --version)"
else
    warn "Docker 未安装，正在安装..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    info "Docker 安装完成"
fi

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
fi

# 配置 Docker 镜像加速（国内服务器必须）
step "配置 Docker 镜像加速"
if [[ ! -f /etc/docker/daemon.json ]] || ! grep -q "registry-mirrors" /etc/docker/daemon.json 2>/dev/null; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'DAEMON'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://docker.m.daocloud.io"
  ]
}
DAEMON
    systemctl daemon-reload
    systemctl restart docker
    info "镜像加速已配置"
else
    info "镜像加速已存在，跳过"
fi

# ----------------------------------------------------------
# 2. 获取项目代码
# ----------------------------------------------------------
step "2/6 获取项目代码"

if [[ -d "${PROJECT_DIR}/.git" ]]; then
    info "项目已存在，拉取最新代码..."
    cd "${PROJECT_DIR}"
    git pull || warn "git pull 失败，使用现有代码继续"
else
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
    info "项目已 clone 到 ${PROJECT_DIR}"
fi

cd "${PROJECT_DIR}"

# ----------------------------------------------------------
# 3. 配置 .env
# ----------------------------------------------------------
step "3/6 配置环境变量"

if [[ -f ".env" ]]; then
    info ".env 已存在"
else
    if [[ -f "config/env.example" ]]; then
        cp config/env.example .env

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

        # 补充 env.example 中没有的变量
        cat >> .env << EXTRA

# --- Resin 代理池网关 ---
RESIN_ADMIN_TOKEN=${RESIN_ADMIN}
RESIN_PROXY_TOKEN=${RESIN_PROXY}

# --- GPT Manager ---
MANAGER_TARGET=100
CLIPROXYAPI_MGMT_KEY=mgmt-$(openssl rand -hex 8)
GPTMAIL_API_KEY=gpt-test

# --- GPT Register 代理（通过 Resin） ---
GPT_REGISTER_PROXY=http://${RESIN_PROXY}:@resin:2260

# --- 域名配置 ---
MAIN_DOMAIN=localhost
REGISTER_DOMAIN=
CF_TUNNEL_TOKEN=
EXTRA
        info ".env 已生成，密钥已自动填充"
    else
        error "config/env.example 不存在，无法生成 .env"
    fi
fi

# 确保 .env 中有 RESIN 相关变量（已有 .env 但缺变量的情况）
if ! grep -q "^RESIN_ADMIN_TOKEN=" .env 2>/dev/null; then
    RESIN_ADMIN=$(openssl rand -hex 16)
    RESIN_PROXY=$(openssl rand -hex 16)
    cat >> .env << EXTRA2

# --- Resin 代理池网关（自动补充） ---
RESIN_ADMIN_TOKEN=${RESIN_ADMIN}
RESIN_PROXY_TOKEN=${RESIN_PROXY}
EXTRA2
    warn "已补充 RESIN_ADMIN_TOKEN / RESIN_PROXY_TOKEN 到 .env"
fi

if ! grep -q "^MAIN_DOMAIN=" .env 2>/dev/null; then
    cat >> .env << 'EXTRA3'

# --- 域名配置 ---
MAIN_DOMAIN=localhost
REGISTER_DOMAIN=
CF_TUNNEL_TOKEN=
EXTRA3
    info "已补充域名配置到 .env"
fi

# 交互式配置域名
echo ""
echo -e "${BOLD}请输入域名配置:${NC}"
echo -n -e "${CYAN}主域名 (如 xy123.me，直接回车用 localhost): ${NC}"
read -r INPUT_DOMAIN
INPUT_DOMAIN=${INPUT_DOMAIN:-localhost}
sed -i "s|^MAIN_DOMAIN=.*|MAIN_DOMAIN=${INPUT_DOMAIN}|" .env
info "域名已配置: ${INPUT_DOMAIN}"

# ----------------------------------------------------------
# 4. 创建数据目录
# ----------------------------------------------------------
step "4/6 创建数据目录"

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
# 5. 启动服务（只启动核心 + resin + gpt-register）
# ----------------------------------------------------------
step "5/6 启动服务"

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

info "启动 Resin 代理池..."
docker compose -f docker-compose.reverse.yml up -d resin

info "等待 Resin 启动..."
sleep 5

info "构建并启动 GPT Register..."
docker compose -f docker-compose.reverse.yml build gpt-register 2>&1 | tail -5 || warn "gpt-register 构建失败"
docker compose -f docker-compose.reverse.yml up -d gpt-register 2>&1 || warn "gpt-register 启动失败"

# ----------------------------------------------------------
# 6. 部署完成 + 宝塔 Nginx 配置指引
# ----------------------------------------------------------
step "6/6 部署完成"

sleep 3

echo ""
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
echo ""

PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "<服务器IP>")

echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  核心服务部署完成！${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo ""
echo -e "  服务器公网 IP: ${CYAN}${PUBLIC_IP}${NC}"
echo -e "  New API 内部:  ${CYAN}http://127.0.0.1:3000${NC}"
echo -e "  Resin 内部:    ${CYAN}http://127.0.0.1:2260${NC}"
echo -e "  GPT Register:  ${CYAN}http://127.0.0.1:9005${NC}"
echo ""
echo -e "  默认账号: ${CYAN}root${NC} / ${CYAN}123456${NC} ${RED}(请立即修改！)${NC}"
echo -e "  Root Token: ${CYAN}$(grep '^INITIAL_ROOT_TOKEN=' .env 2>/dev/null | cut -d'=' -f2-)${NC}"
echo ""
echo -e "${YELLOW}${BOLD}  接下来请在宝塔面板中配置 Nginx 反向代理:${NC}"
echo ""
echo -e "  ${BOLD}1. 主站点 ${INPUT_DOMAIN}:${NC}"
echo -e "     宝塔 → 网站 → 添加站点 → 域名填 ${CYAN}${INPUT_DOMAIN}${NC}"
echo -e "     → SSL → Let's Encrypt → 申请证书"
echo -e "     → 反向代理 → 目标URL填 ${CYAN}http://127.0.0.1:3000${NC}"
echo ""
echo -e "  ${BOLD}2. 或者使用项目自带的 Nginx 配置:${NC}"
echo -e "     ${CYAN}cp ${PROJECT_DIR}/nginx/api.conf /www/server/panel/vhost/nginx/${INPUT_DOMAIN}.conf${NC}"
echo -e "     然后修改域名和 SSL 证书路径，重载 Nginx"
echo ""
echo -e "  ${BOLD}管理命令:${NC}"
echo -e "  cd ${PROJECT_DIR}"
echo -e "  docker compose ps                                              # 核心服务状态"
echo -e "  docker compose -f docker-compose.reverse.yml ps                # 代理层状态"
echo -e "  docker compose logs -f new-api                                 # New API 日志"
echo -e "  docker compose -f docker-compose.reverse.yml logs -f resin     # Resin 日志"
echo ""
echo -e "  ${YELLOW}请确保域名 DNS 已解析到 ${PUBLIC_IP}${NC}"
echo -e "  ${YELLOW}请在宝塔面板安全中放行 80 和 443 端口${NC}"
echo ""
