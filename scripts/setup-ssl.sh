#!/bin/bash
# ============================================================
# Let's Encrypt SSL 证书自动申请脚本
# 用途：为 API 中转站自动申请和配置 SSL 证书
# 用法：sudo bash setup-ssl.sh your-domain.com
# ============================================================

# 遇到任何错误立即退出，避免在错误状态下继续执行
set -e

# ==================== 颜色定义（美化输出） ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色（重置）

# ==================== 辅助函数 ====================
# 输出信息日志
info() {
    echo -e "${CYAN}[信息]${NC} $1"
}

# 输出成功日志
success() {
    echo -e "${GREEN}[成功]${NC} $1"
}

# 输出警告日志
warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

# 输出错误日志并退出
error() {
    echo -e "${RED}[错误]${NC} $1"
    exit 1
}

# ==================== 参数校验 ====================
# 检查是否提供了域名参数
DOMAIN="$1"

if [ -z "$DOMAIN" ]; then
    error "请提供域名参数！"
    echo ""
    echo "用法：sudo bash $0 <你的域名>"
    echo "示例：sudo bash $0 api.example.com"
    exit 1
fi

info "准备为域名 ${GREEN}${DOMAIN}${NC} 申请 SSL 证书..."
echo ""

# ==================== 权限检查 ====================
# certbot 需要 root 权限来监听 80 端口和写入证书目录
if [ "$EUID" -ne 0 ]; then
    error "此脚本需要 root 权限运行，请使用 sudo 执行！"
fi

# ==================== 安装 certbot ====================
install_certbot() {
    # 检查 certbot 是否已经安装
    if command -v certbot &> /dev/null; then
        success "certbot 已安装，版本：$(certbot --version 2>&1)"
        return 0
    fi

    info "正在安装 certbot..."

    # 优先尝试使用 snap 安装（官方推荐方式）
    if command -v snap &> /dev/null; then
        info "检测到 snap，使用 snap 安装 certbot..."
        snap install --classic certbot 2>/dev/null || true

        # 创建符号链接确保命令可用
        if [ ! -L /usr/bin/certbot ] && [ -f /snap/bin/certbot ]; then
            ln -sf /snap/bin/certbot /usr/bin/certbot
        fi

        if command -v certbot &> /dev/null; then
            success "certbot 通过 snap 安装成功！"
            return 0
        fi
    fi

    # snap 安装失败或不可用时，使用 apt 安装
    if command -v apt-get &> /dev/null; then
        info "使用 apt 安装 certbot..."
        apt-get update -y
        apt-get install -y certbot
        if command -v certbot &> /dev/null; then
            success "certbot 通过 apt 安装成功！"
            return 0
        fi
    fi

    # 如果两种方式都失败，报错退出
    error "无法自动安装 certbot，请手动安装后重试！
    Ubuntu/Debian: sudo apt install certbot
    CentOS/RHEL:   sudo yum install certbot
    官方文档：https://certbot.eff.org/"
}

# 执行 certbot 安装
install_certbot

# ==================== 停止 Nginx（释放 80 端口） ====================
# certbot standalone 模式需要监听 80 端口，如果 nginx 正在运行则需要先停止
NGINX_WAS_RUNNING=false

if systemctl is-active --quiet nginx 2>/dev/null; then
    NGINX_WAS_RUNNING=true
    warn "检测到 Nginx 正在运行，临时停止以释放 80 端口..."
    systemctl stop nginx
    success "Nginx 已临时停止"
elif pgrep -x nginx &> /dev/null; then
    NGINX_WAS_RUNNING=true
    warn "检测到 Nginx 进程，临时停止..."
    nginx -s stop 2>/dev/null || killall nginx 2>/dev/null || true
    sleep 2
    success "Nginx 已临时停止"
else
    info "Nginx 未运行，无需停止"
fi

# ==================== 申请 SSL 证书 ====================
info "正在向 Let's Encrypt 申请 SSL 证书..."
info "域名：${DOMAIN}"
info "邮箱：admin@${DOMAIN}（用于接收证书过期提醒）"
echo ""

certbot certonly \
    --standalone \
    -d "$DOMAIN" \
    --agree-tos \
    --email "admin@${DOMAIN}" \
    --non-interactive

# 检查证书是否申请成功
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"

if [ -d "$CERT_PATH" ]; then
    success "SSL 证书申请成功！"
else
    # 如果 Nginx 之前在运行，恢复它
    if [ "$NGINX_WAS_RUNNING" = true ]; then
        systemctl start nginx 2>/dev/null || nginx 2>/dev/null || true
    fi
    error "SSL 证书申请失败，请检查：
    1. 域名 ${DOMAIN} 是否已正确解析到本服务器 IP
    2. 服务器 80 端口是否对外开放（检查防火墙规则）
    3. 域名是否已备案（国内服务器可能需要）"
fi

# ==================== 恢复 Nginx ====================
if [ "$NGINX_WAS_RUNNING" = true ]; then
    info "正在恢复 Nginx 服务..."
    systemctl start nginx 2>/dev/null || nginx 2>/dev/null || true
    success "Nginx 已恢复运行"
fi

# ==================== 设置自动续期定时任务 ====================
info "正在配置证书自动续期..."

# 定义 cron 任务内容：每天凌晨 2:30 检查并续期证书，续期成功后重载 Nginx
CRON_JOB="30 2 * * * certbot renew --quiet --deploy-hook \"systemctl reload nginx\" >> /var/log/certbot-renew.log 2>&1"

# 检查是否已存在续期任务，避免重复添加
if crontab -l 2>/dev/null | grep -q "certbot renew"; then
    warn "检测到已有 certbot 自动续期任务，跳过添加"
else
    # 将新 cron 任务追加到当前用户的 crontab
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    success "自动续期定时任务已添加（每天凌晨 2:30 执行）"
fi

# ==================== 验证证书信息 ====================
info "正在验证证书信息..."
echo ""
echo "-------------------------------------------------------"
openssl x509 -in "${CERT_PATH}/fullchain.pem" -noout -subject -dates -issuer 2>/dev/null || true
echo "-------------------------------------------------------"
echo ""

# ==================== 输出完成信息 ====================
echo ""
echo "========================================================="
success "SSL 证书配置全部完成！"
echo "========================================================="
echo ""
echo -e "${CYAN}证书文件路径：${NC}"
echo -e "  证书文件：${GREEN}${CERT_PATH}/fullchain.pem${NC}"
echo -e "  私钥文件：${GREEN}${CERT_PATH}/privkey.pem${NC}"
echo ""
echo -e "${CYAN}后续操作步骤：${NC}"
echo ""
echo -e "  ${YELLOW}1. 配置 Nginx${NC}"
echo "     将 nginx/api.conf 中的 YOUR_DOMAIN 替换为 ${DOMAIN}："
echo "     sed -i 's/YOUR_DOMAIN/${DOMAIN}/g' /etc/nginx/conf.d/api.conf"
echo ""
echo -e "  ${YELLOW}2. 测试 Nginx 配置${NC}"
echo "     nginx -t"
echo ""
echo -e "  ${YELLOW}3. 重载 Nginx 使配置生效${NC}"
echo "     systemctl reload nginx"
echo ""
echo -e "  ${YELLOW}4. 验证 HTTPS 是否正常${NC}"
echo "     curl -I https://${DOMAIN}"
echo ""
echo -e "${CYAN}证书管理命令：${NC}"
echo "  查看所有证书：certbot certificates"
echo "  手动续期测试：certbot renew --dry-run"
echo "  强制续期证书：certbot renew --force-renewal"
echo ""
echo -e "${CYAN}注意事项：${NC}"
echo "  - Let's Encrypt 证书有效期为 90 天"
echo "  - 自动续期任务已配置，无需手动操作"
echo "  - 续期日志位于 /var/log/certbot-renew.log"
echo "  - 如遇问题请检查 80/443 端口是否开放"
echo ""
success "祝你使用愉快！"
