#!/bin/bash

# ============================================================
# Catch-All 邮箱配置脚本
# 用途：为批量账号注册设置域名邮箱的 catch-all（全捕获）功能
# 原理：任意前缀@你的域名 都会转发到同一个真实邮箱
# 例如：abc123@yourdomain.com → your-real@gmail.com
# 用法：sudo bash setup-catchall.sh
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

# 输出错误日志但不退出（用于非致命错误）
error_noexit() {
    echo -e "${RED}[错误]${NC} $1"
}

# 输出步骤标题
step() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
}

# ==================== 全局变量 ====================

# 用户的域名，后续通过交互输入赋值
DOMAIN=""

# Cloudflare API 基础地址
CF_API_BASE="https://api.cloudflare.com/client/v4"

# ==================== 生成随机邮箱地址 ====================
# 使用 openssl 生成随机十六进制前缀，拼接域名
# 可在注册脚本中直接调用此函数
generate_email() {
    local domain="${1:-$DOMAIN}"
    if [ -z "$domain" ]; then
        echo "错误：未指定域名" >&2
        return 1
    fi
    # 生成 4 字节（8 个十六进制字符）的随机前缀
    local prefix
    prefix=$(openssl rand -hex 4 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | head -c 8)
    echo "${prefix}@${domain}"
}

# ==================== 输入域名 ====================
# 提示用户输入域名，并做基本格式校验
prompt_domain() {
    echo ""
    read -rp "$(echo -e "${CYAN}请输入你的域名（例如 example.com）：${NC}")" DOMAIN

    # 校验域名不能为空
    if [ -z "$DOMAIN" ]; then
        error "域名不能为空！"
    fi

    # 去除协议前缀（用户可能误输入 https://）
    DOMAIN=$(echo "$DOMAIN" | sed -E 's|^https?://||' | sed 's|/.*||' | tr '[:upper:]' '[:lower:]')

    # 基本格式校验：至少包含一个点
    if ! echo "$DOMAIN" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; then
        error "域名格式不正确：${DOMAIN}，请输入有效的域名（如 example.com）"
    fi

    success "域名已确认：${GREEN}${DOMAIN}${NC}"
}

# ==================== 模式一：Cloudflare Email Routing ====================
setup_cloudflare() {
    step "模式一：Cloudflare Email Routing（推荐）"
    echo ""
    info "Cloudflare Email Routing 是免费的邮件路由服务"
    info "它可以将 *@${DOMAIN} 的所有邮件转发到你指定的真实邮箱"
    info "无需自建邮件服务器，零维护成本"
    echo ""

    # ---------- 获取用户输入 ----------

    # 输入 Cloudflare API Token
    info "请准备你的 Cloudflare API Token"
    info "获取方式：Cloudflare Dashboard → My Profile → API Tokens → Create Token"
    info "所需权限：Zone.Zone (Read) + Zone.Email Routing Rules (Edit)"
    echo ""
    read -rp "$(echo -e "${CYAN}请输入 Cloudflare API Token：${NC}")" CF_API_TOKEN

    if [ -z "$CF_API_TOKEN" ]; then
        error "API Token 不能为空！"
    fi

    # 输入转发目标邮箱
    echo ""
    read -rp "$(echo -e "${CYAN}请输入接收转发邮件的真实邮箱地址：${NC}")" FORWARD_TO

    if [ -z "$FORWARD_TO" ]; then
        error "转发目标邮箱不能为空！"
    fi

    # 基本邮箱格式校验
    if ! echo "$FORWARD_TO" | grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
        error "邮箱格式不正确：${FORWARD_TO}"
    fi

    echo ""
    info "配置摘要："
    info "  域名：${GREEN}${DOMAIN}${NC}"
    info "  转发规则：${GREEN}*@${DOMAIN}${NC} → ${GREEN}${FORWARD_TO}${NC}"
    info "  API Token：${GREEN}${CF_API_TOKEN:0:8}...（已隐藏）${NC}"
    echo ""

    # ---------- 步骤 1：验证 API Token ----------

    step "步骤 1/4：验证 API Token 有效性"

    info "正在验证 API Token..."
    VERIFY_RESPONSE=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CF_API_BASE}/user/tokens/verify" 2>/dev/null)

    VERIFY_HTTP_CODE=$(echo "$VERIFY_RESPONSE" | tail -1)
    VERIFY_BODY=$(echo "$VERIFY_RESPONSE" | sed '$d')

    if [ "$VERIFY_HTTP_CODE" != "200" ]; then
        error_noexit "API Token 验证失败（HTTP: ${VERIFY_HTTP_CODE}）"
        error_noexit "响应内容：${VERIFY_BODY}"
        cloudflare_manual_instructions
        exit 1
    fi

    # 检查 API 返回的 success 字段
    if ! echo "$VERIFY_BODY" | grep -q '"success":true'; then
        error_noexit "API Token 无效或已过期"
        cloudflare_manual_instructions
        exit 1
    fi

    success "API Token 验证通过"

    # ---------- 步骤 2：获取域名的 Zone ID ----------

    step "步骤 2/4：获取域名 Zone ID"

    info "正在查询域名 ${DOMAIN} 对应的 Zone..."
    ZONE_RESPONSE=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CF_API_BASE}/zones?name=${DOMAIN}&status=active" 2>/dev/null)

    ZONE_HTTP_CODE=$(echo "$ZONE_RESPONSE" | tail -1)
    ZONE_BODY=$(echo "$ZONE_RESPONSE" | sed '$d')

    if [ "$ZONE_HTTP_CODE" != "200" ]; then
        error_noexit "查询 Zone 失败（HTTP: ${ZONE_HTTP_CODE}）"
        error_noexit "响应内容：${ZONE_BODY}"
        cloudflare_manual_instructions
        exit 1
    fi

    # 从返回的 JSON 中提取 Zone ID
    # 使用 grep + sed 提取，避免依赖 jq
    ZONE_ID=$(echo "$ZONE_BODY" | grep -oP '"id"\s*:\s*"[a-f0-9]{32}"' | head -1 | grep -oP '[a-f0-9]{32}')

    if [ -z "$ZONE_ID" ]; then
        error_noexit "未找到域名 ${DOMAIN} 的 Zone"
        error_noexit "请确认该域名已添加到你的 Cloudflare 账户，且状态为 Active"
        cloudflare_manual_instructions
        exit 1
    fi

    success "Zone ID 获取成功：${GREEN}${ZONE_ID}${NC}"

    # ---------- 步骤 3：配置 Catch-All 路由规则 ----------

    step "步骤 3/4：配置 Catch-All 路由规则"

    # 先检查是否已启用 Email Routing
    info "正在检查 Email Routing 状态..."
    ER_STATUS_RESPONSE=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CF_API_BASE}/zones/${ZONE_ID}/email/routing" 2>/dev/null)

    ER_STATUS_HTTP=$(echo "$ER_STATUS_RESPONSE" | tail -1)
    ER_STATUS_BODY=$(echo "$ER_STATUS_RESPONSE" | sed '$d')

    if [ "$ER_STATUS_HTTP" = "200" ]; then
        if echo "$ER_STATUS_BODY" | grep -q '"enabled":true'; then
            success "Email Routing 已启用"
        else
            info "Email Routing 尚未启用，正在尝试启用..."
            ENABLE_RESPONSE=$(curl -s -w "\n%{http_code}" \
                -X PUT \
                -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '{"enabled":true}' \
                "${CF_API_BASE}/zones/${ZONE_ID}/email/routing/enable" 2>/dev/null)

            ENABLE_HTTP=$(echo "$ENABLE_RESPONSE" | tail -1)
            if [ "$ENABLE_HTTP" = "200" ]; then
                success "Email Routing 已成功启用"
            else
                warn "自动启用 Email Routing 可能失败，请手动在 Cloudflare Dashboard 中启用"
            fi
        fi
    else
        warn "无法检查 Email Routing 状态（HTTP: ${ER_STATUS_HTTP}），继续尝试配置..."
    fi

    # 先确保目标邮箱已添加为 Destination Address
    info "正在添加转发目标邮箱 ${FORWARD_TO} 为 Destination Address..."
    info "注意：Cloudflare 会向该邮箱发送验证邮件，请注意查收并点击验证链接"

    DEST_RESPONSE=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${FORWARD_TO}\"}" \
        "${CF_API_BASE}/accounts" 2>/dev/null)

    # 获取 account_id（需要通过 zones 获取）
    ACCOUNT_ID=$(echo "$ZONE_BODY" | grep -oP '"account":\{"id":"[a-f0-9]+"' | grep -oP '[a-f0-9]{32}' | head -1)

    if [ -n "$ACCOUNT_ID" ]; then
        # 添加 destination address
        DEST_ADD_RESPONSE=$(curl -s -w "\n%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"email\":\"${FORWARD_TO}\"}" \
            "${CF_API_BASE}/accounts/${ACCOUNT_ID}/email/routing/addresses" 2>/dev/null)

        DEST_ADD_HTTP=$(echo "$DEST_ADD_RESPONSE" | tail -1)
        DEST_ADD_BODY=$(echo "$DEST_ADD_RESPONSE" | sed '$d')

        if [ "$DEST_ADD_HTTP" = "200" ]; then
            if echo "$DEST_ADD_BODY" | grep -q '"success":true'; then
                success "转发目标邮箱已添加，请查收验证邮件并完成验证"
            else
                warn "添加目标邮箱可能失败，如果该邮箱已存在则可忽略"
            fi
        else
            warn "添加目标邮箱请求返回 HTTP ${DEST_ADD_HTTP}（如果该邮箱已添加过则可忽略）"
        fi
    else
        warn "无法获取 Account ID，跳过自动添加目标邮箱，请手动在 Dashboard 中添加"
    fi

    # 配置 Catch-All 规则
    info "正在配置 Catch-All 路由规则..."
    info "规则：所有发送到 *@${DOMAIN} 的邮件 → 转发到 ${FORWARD_TO}"

    CATCHALL_RESPONSE=$(curl -s -w "\n%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"enabled\": true,
            \"name\": \"Catch-All 全捕获规则\",
            \"actions\": [
                {
                    \"type\": \"forward\",
                    \"value\": [\"${FORWARD_TO}\"]
                }
            ]
        }" \
        "${CF_API_BASE}/zones/${ZONE_ID}/email/routing/rules/catch_all" 2>/dev/null)

    CATCHALL_HTTP=$(echo "$CATCHALL_RESPONSE" | tail -1)
    CATCHALL_BODY=$(echo "$CATCHALL_RESPONSE" | sed '$d')

    if [ "$CATCHALL_HTTP" = "200" ]; then
        if echo "$CATCHALL_BODY" | grep -q '"success":true'; then
            success "Catch-All 路由规则配置成功！"
        else
            # 提取错误信息
            CF_ERRORS=$(echo "$CATCHALL_BODY" | grep -oP '"message"\s*:\s*"[^"]*"' | head -3)
            error_noexit "Catch-All 规则配置失败"
            error_noexit "API 返回：${CF_ERRORS}"
            cloudflare_manual_instructions
            exit 1
        fi
    else
        error_noexit "Catch-All 规则配置请求失败（HTTP: ${CATCHALL_HTTP}）"
        error_noexit "响应内容：${CATCHALL_BODY}"
        cloudflare_manual_instructions
        exit 1
    fi

    # ---------- 步骤 4：检查 MX 记录 ----------

    step "步骤 4/4：检查 MX 记录配置"

    info "正在查询域名 ${DOMAIN} 的 MX 记录..."

    # 优先使用 dig 查询 MX 记录
    if command -v dig &> /dev/null; then
        MX_RECORDS=$(dig +short MX "${DOMAIN}" 2>/dev/null)
    elif command -v nslookup &> /dev/null; then
        MX_RECORDS=$(nslookup -type=mx "${DOMAIN}" 2>/dev/null | grep "mail exchanger" || true)
    elif command -v host &> /dev/null; then
        MX_RECORDS=$(host -t MX "${DOMAIN}" 2>/dev/null | grep "mail" || true)
    else
        warn "未找到 DNS 查询工具（dig/nslookup/host），跳过 MX 记录检查"
        MX_RECORDS=""
    fi

    if [ -n "$MX_RECORDS" ]; then
        # 检查是否包含 Cloudflare 的 MX 记录
        if echo "$MX_RECORDS" | grep -qi "route.*cloudflare\|mx.*cloudflare\|isaac\|amir\|mailstream"; then
            success "MX 记录已正确指向 Cloudflare"
            info "当前 MX 记录："
            echo "$MX_RECORDS" | while read -r line; do
                echo -e "    ${GREEN}${line}${NC}"
            done
        else
            warn "MX 记录可能未指向 Cloudflare Email Routing"
            info "当前 MX 记录："
            echo "$MX_RECORDS" | while read -r line; do
                echo -e "    ${YELLOW}${line}${NC}"
            done
            echo ""
            info "Cloudflare Email Routing 需要以下 MX 记录："
            echo -e "    ${CYAN}${DOMAIN}  MX  isaac.mx.cloudflare.net   优先级 13${NC}"
            echo -e "    ${CYAN}${DOMAIN}  MX  linda.mx.cloudflare.net   优先级 86${NC}"
            echo -e "    ${CYAN}${DOMAIN}  MX  amir.mx.cloudflare.net    优先级 3${NC}"
            info "如果你使用 Cloudflare DNS 管理域名，启用 Email Routing 后会自动添加"
            info "否则请手动添加上述 MX 记录到你的 DNS 服务商"
        fi
    else
        warn "无法查询 MX 记录，请手动确认以下 MX 记录已正确配置："
        echo -e "    ${CYAN}${DOMAIN}  MX  isaac.mx.cloudflare.net   优先级 13${NC}"
        echo -e "    ${CYAN}${DOMAIN}  MX  linda.mx.cloudflare.net   优先级 86${NC}"
        echo -e "    ${CYAN}${DOMAIN}  MX  amir.mx.cloudflare.net    优先级 3${NC}"
    fi

    success "Cloudflare Email Routing 配置完成！"
}

# ==================== Cloudflare 手动操作指南 ====================
# 当 API 操作失败时，引导用户通过 Dashboard 手动完成配置
cloudflare_manual_instructions() {
    echo ""
    echo -e "${YELLOW}=========================================================${NC}"
    echo -e "${YELLOW}  API 操作失败，请按以下步骤手动配置：${NC}"
    echo -e "${YELLOW}=========================================================${NC}"
    echo ""
    echo -e "${CYAN}1. 登录 Cloudflare Dashboard：${NC}"
    echo "   https://dash.cloudflare.com/"
    echo ""
    echo -e "${CYAN}2. 选择你的域名 ${DOMAIN}${NC}"
    echo ""
    echo -e "${CYAN}3. 进入 Email → Email Routing${NC}"
    echo ""
    echo -e "${CYAN}4. 启用 Email Routing（如果尚未启用）${NC}"
    echo "   - 按照提示添加所需的 MX 和 TXT 记录"
    echo ""
    echo -e "${CYAN}5. 添加 Destination Address（转发目标邮箱）${NC}"
    echo "   - 点击 'Destination addresses' 标签"
    echo "   - 添加你的真实邮箱地址"
    echo "   - 查收验证邮件并完成验证"
    echo ""
    echo -e "${CYAN}6. 配置 Catch-All 规则${NC}"
    echo "   - 在 'Routing rules' 标签页底部找到 'Catch-all address'"
    echo "   - 将动作设为 'Forward to' 并选择你验证过的邮箱"
    echo "   - 保存设置"
    echo ""
    echo -e "${CYAN}7. 等待 DNS 生效（通常几分钟内）${NC}"
    echo ""
    echo -e "${YELLOW}=========================================================${NC}"
}

# ==================== 模式二：Self-hosted Postfix Catch-All ====================
setup_postfix() {
    step "模式二：自建 Postfix 邮件服务器（Catch-All）"
    echo ""
    info "此模式将在本机安装 Postfix 邮件服务器并配置 catch-all"
    info "所有发往 *@${DOMAIN} 的邮件将被本地 catchall 用户接收"
    warn "自建邮件服务器需要确保：服务器 IP 未被黑名单、25 端口可用、有正确的 rDNS"
    echo ""

    # ---------- 权限检查 ----------

    if [ "$EUID" -ne 0 ]; then
        error "自建邮件服务器模式需要 root 权限，请使用 sudo 执行此脚本！"
    fi

    # ---------- 步骤 1：安装依赖 ----------

    step "步骤 1/5：安装 Postfix 和 Dovecot"

    # 预设 Postfix 安装选项，避免交互式弹窗
    info "正在预配置 Postfix 安装选项..."
    export DEBIAN_FRONTEND=noninteractive
    debconf-set-selections <<< "postfix postfix/mailname string mail.${DOMAIN}"
    debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

    info "正在更新软件包列表..."
    apt-get update -y

    info "正在安装 postfix..."
    apt-get install -y postfix

    info "正在安装 dovecot-imapd（用于 IMAP 收信）..."
    apt-get install -y dovecot-imapd

    # 安装 mailutils 以便使用 mail 命令发送测试邮件
    info "正在安装 mailutils..."
    apt-get install -y mailutils 2>/dev/null || warn "mailutils 安装失败，测试邮件功能可能受限"

    success "所有依赖安装完成"

    # ---------- 步骤 2：配置 Postfix ----------

    step "步骤 2/5：配置 Postfix 主配置文件"

    # 备份原始配置文件
    POSTFIX_MAIN_CF="/etc/postfix/main.cf"
    if [ -f "$POSTFIX_MAIN_CF" ]; then
        cp "$POSTFIX_MAIN_CF" "${POSTFIX_MAIN_CF}.bak.$(date +%s)"
        info "已备份原配置文件"
    fi

    info "正在写入 Postfix 主配置..."

    # 写入核心配置项
    # 使用 postconf 命令逐项设置，比直接覆盖文件更安全
    postconf -e "myhostname = mail.${DOMAIN}"
    postconf -e "mydomain = ${DOMAIN}"
    postconf -e "myorigin = \$mydomain"
    postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
    postconf -e "inet_interfaces = all"
    postconf -e "inet_protocols = ipv4"
    postconf -e "home_mailbox = Maildir/"

    # 配置虚拟别名映射，使用正则表达式实现 catch-all
    postconf -e "virtual_alias_maps = regexp:/etc/postfix/virtual-regexp"

    # 设置邮件大小限制（50MB）
    postconf -e "message_size_limit = 52428800"

    # 设置邮箱大小限制（1GB）
    postconf -e "mailbox_size_limit = 1073741824"

    # 基本安全设置
    postconf -e "smtpd_banner = \$myhostname ESMTP"
    postconf -e "smtpd_helo_required = yes"
    postconf -e "disable_vrfy_command = yes"

    success "Postfix 主配置已写入"

    # ---------- 步骤 3：配置 Catch-All 正则映射 ----------

    step "步骤 3/5：配置 Catch-All 虚拟别名"

    VIRTUAL_REGEXP="/etc/postfix/virtual-regexp"

    info "正在创建正则表达式虚拟别名文件..."

    # 将所有发往 @DOMAIN 的邮件重定向到本地 catchall 用户
    cat > "$VIRTUAL_REGEXP" << VIRTUAL_EOF
# Catch-All 正则映射
# 任何发往 @${DOMAIN} 的邮件都转发到本地 catchall 用户
# 格式：正则表达式    目标地址
/.*@${DOMAIN//./\\.}/    catchall@localhost
VIRTUAL_EOF

    # 生成 Postfix 映射数据库
    postmap "$VIRTUAL_REGEXP"

    success "虚拟别名映射已创建：${GREEN}${VIRTUAL_REGEXP}${NC}"
    info "规则：/.*@${DOMAIN}/ → catchall@localhost"

    # ---------- 步骤 4：创建 catchall 本地用户 ----------

    step "步骤 4/5：创建本地 catchall 用户"

    if id "catchall" &>/dev/null; then
        warn "用户 catchall 已存在，跳过创建"
    else
        info "正在创建系统用户 catchall..."
        # 创建用户，不创建家目录登录 shell 设为 nologin（安全考虑）
        useradd -m -s /usr/sbin/nologin catchall
        success "用户 catchall 已创建"
    fi

    # 确保 Maildir 目录存在
    CATCHALL_MAILDIR="/home/catchall/Maildir"
    if [ ! -d "$CATCHALL_MAILDIR" ]; then
        mkdir -p "${CATCHALL_MAILDIR}/new"
        mkdir -p "${CATCHALL_MAILDIR}/cur"
        mkdir -p "${CATCHALL_MAILDIR}/tmp"
        chown -R catchall:catchall "${CATCHALL_MAILDIR}"
        info "已创建 Maildir 目录：${CATCHALL_MAILDIR}"
    fi

    success "catchall 用户配置完成"

    # ---------- 步骤 5：重启服务 ----------

    step "步骤 5/5：重启邮件服务"

    info "正在重启 Postfix..."
    systemctl restart postfix
    systemctl enable postfix
    success "Postfix 已重启并设为开机自启"

    info "正在重启 Dovecot..."
    systemctl restart dovecot
    systemctl enable dovecot
    success "Dovecot 已重启并设为开机自启"

    # 验证服务状态
    if systemctl is-active --quiet postfix; then
        success "Postfix 服务运行正常"
    else
        error_noexit "Postfix 服务未正常启动，请检查日志：journalctl -u postfix"
    fi

    if systemctl is-active --quiet dovecot; then
        success "Dovecot 服务运行正常"
    else
        error_noexit "Dovecot 服务未正常启动，请检查日志：journalctl -u dovecot"
    fi

    # ---------- 输出需要配置的 DNS 记录 ----------

    echo ""
    echo -e "${CYAN}=========================================================${NC}"
    echo -e "${CYAN}  请在你的 DNS 服务商添加以下记录：${NC}"
    echo -e "${CYAN}=========================================================${NC}"
    echo ""

    # 尝试获取服务器公网 IP
    SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
                curl -s --max-time 5 https://icanhazip.com 2>/dev/null || \
                echo "<你的服务器IP>")

    echo -e "${YELLOW}1. MX 记录（必须）：${NC}"
    echo -e "   类型: MX"
    echo -e "   名称: ${GREEN}${DOMAIN}${NC}"
    echo -e "   值:   ${GREEN}mail.${DOMAIN}${NC}"
    echo -e "   优先级: ${GREEN}10${NC}"
    echo ""

    echo -e "${YELLOW}2. A 记录（必须）：${NC}"
    echo -e "   类型: A"
    echo -e "   名称: ${GREEN}mail.${DOMAIN}${NC}"
    echo -e "   值:   ${GREEN}${SERVER_IP}${NC}"
    echo ""

    echo -e "${YELLOW}3. SPF 记录（强烈建议）：${NC}"
    echo -e "   类型: TXT"
    echo -e "   名称: ${GREEN}${DOMAIN}${NC}"
    echo -e "   值:   ${GREEN}v=spf1 mx a ip4:${SERVER_IP} ~all${NC}"
    echo ""

    echo -e "${YELLOW}4. rDNS / PTR 记录（建议）：${NC}"
    echo -e "   需要联系你的 VPS 服务商设置反向 DNS"
    echo -e "   将 ${GREEN}${SERVER_IP}${NC} 的 PTR 记录指向 ${GREEN}mail.${DOMAIN}${NC}"
    echo ""

    # 尝试检查是否安装了 opendkim，提示 DKIM 配置
    if command -v opendkim &> /dev/null; then
        echo -e "${YELLOW}5. DKIM 记录（已检测到 opendkim）：${NC}"
        echo -e "   请使用 opendkim-genkey 生成密钥对并添加对应的 TXT 记录"
    else
        echo -e "${YELLOW}5. DKIM 记录（可选，防止邮件被标记为垃圾邮件）：${NC}"
        echo -e "   安装 opendkim：apt-get install opendkim opendkim-tools"
        echo -e "   生成密钥：opendkim-genkey -s mail -d ${DOMAIN}"
        echo -e "   将生成的公钥添加为 TXT 记录"
    fi
    echo ""

    echo -e "${YELLOW}6. DMARC 记录（可选）：${NC}"
    echo -e "   类型: TXT"
    echo -e "   名称: ${GREEN}_dmarc.${DOMAIN}${NC}"
    echo -e "   值:   ${GREEN}v=DMARC1; p=none; rua=mailto:postmaster@${DOMAIN}${NC}"
    echo ""

    success "Postfix Catch-All 邮件服务器配置完成！"
}

# ==================== 验证 Catch-All 功能 ====================
# 发送测试邮件到一个随机地址，检查是否能被正确接收
verify_catchall() {
    step "验证 Catch-All 功能"

    # 生成带时间戳的测试地址，确保唯一性
    TEST_ADDR="test-$(date +%s)@${DOMAIN}"

    info "正在发送测试邮件到：${GREEN}${TEST_ADDR}${NC}"

    # 尝试使用本地 sendmail 发送测试邮件
    if command -v sendmail &> /dev/null; then
        echo "Subject: Catch-All Test $(date +%s)
From: verify@${DOMAIN}
To: ${TEST_ADDR}

This is an automated test email to verify catch-all configuration.
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
If you received this email, catch-all is working correctly." | sendmail -t 2>/dev/null

        if [ $? -eq 0 ]; then
            success "测试邮件已发送"
        else
            warn "测试邮件发送失败，sendmail 返回错误"
        fi
    elif command -v mail &> /dev/null; then
        echo "This is an automated test email to verify catch-all configuration. Timestamp: $(date '+%Y-%m-%d %H:%M:%S')" | \
            mail -s "Catch-All Test $(date +%s)" "$TEST_ADDR" 2>/dev/null

        if [ $? -eq 0 ]; then
            success "测试邮件已发送"
        else
            warn "测试邮件发送失败"
        fi
    else
        warn "未找到 sendmail 或 mail 命令，无法自动发送测试邮件"
        info "请手动从外部邮箱发送一封邮件到 ${GREEN}${TEST_ADDR}${NC}"
    fi

    # 等待邮件到达
    info "等待邮件到达（最多等待 30 秒）..."
    WAIT_SECONDS=0
    MAX_WAIT=30
    MAIL_RECEIVED=false

    while [ $WAIT_SECONDS -lt $MAX_WAIT ]; do
        sleep 5
        WAIT_SECONDS=$((WAIT_SECONDS + 5))

        # 检查本地 catchall 用户的 Maildir
        if [ -d "/home/catchall/Maildir/new" ]; then
            NEW_MAIL_COUNT=$(find /home/catchall/Maildir/new -type f 2>/dev/null | wc -l)
            if [ "$NEW_MAIL_COUNT" -gt 0 ]; then
                MAIL_RECEIVED=true
                break
            fi
        fi

        info "已等待 ${WAIT_SECONDS} 秒..."
    done

    if [ "$MAIL_RECEIVED" = true ]; then
        success "Catch-All 验证成功！邮件已被正确接收"
        info "catchall 用户的 Maildir 中有 ${NEW_MAIL_COUNT} 封邮件"
    else
        warn "在 ${MAX_WAIT} 秒内未检测到新邮件"
        info "可能的原因："
        info "  1. DNS 记录尚未生效（MX 记录传播可能需要几分钟到几小时）"
        info "  2. 邮件服务器配置有误，请检查日志：tail -f /var/log/mail.log"
        info "  3. 25 端口被防火墙或 VPS 服务商封锁"
        info "  4. 如果使用 Cloudflare 模式，请确认目标邮箱已完成验证"
        echo ""
        info "你可以稍后手动测试：从外部邮箱发送邮件到任意 xxx@${DOMAIN}"
    fi
}

# ==================== 输出使用说明和总结 ====================
print_summary() {
    echo ""
    echo ""
    echo -e "${GREEN}=========================================================${NC}"
    echo -e "${GREEN}           Catch-All 邮箱配置完成！${NC}"
    echo -e "${GREEN}=========================================================${NC}"
    echo ""

    echo -e "${CYAN}---------- Catch-All 工作原理 ----------${NC}"
    echo ""
    echo "  Catch-All（全捕获）会接收发送到你域名下任意地址的邮件。"
    echo "  无论前缀是什么，只要 @后面是你的域名，都会被转发到同一个邮箱。"
    echo ""
    echo -e "  ${GREEN}示例：${NC}"
    echo -e "    abc123@${DOMAIN}     → 你的真实邮箱"
    echo -e "    signup-xyz@${DOMAIN} → 你的真实邮箱"
    echo -e "    random99@${DOMAIN}   → 你的真实邮箱"
    echo -e "    anything@${DOMAIN}   → 你的真实邮箱"
    echo ""

    echo -e "${CYAN}---------- 用于批量账号注册 ----------${NC}"
    echo ""
    echo "  利用 catch-all，你可以为每次注册生成唯一的邮箱地址："
    echo ""
    echo -e "  ${YELLOW}1. 在脚本中生成随机邮箱：${NC}"
    echo "     EMAIL=\$(openssl rand -hex 4)@${DOMAIN}"
    echo "     # 示例输出：a3f7c2d1@${DOMAIN}"
    echo ""
    echo -e "  ${YELLOW}2. 使用本脚本的 generate_email 函数：${NC}"
    echo "     source $(readlink -f "$0" 2>/dev/null || echo "$0")"
    echo "     DOMAIN=\"${DOMAIN}\" generate_email"
    echo ""
    echo -e "  ${YELLOW}3. 一行命令生成：${NC}"
    echo "     echo \$(openssl rand -hex 4)@${DOMAIN}"
    echo ""

    echo -e "${CYAN}---------- 快速验证 ----------${NC}"
    echo ""
    echo "  从任意外部邮箱（如 Gmail）发送一封邮件到："
    echo -e "    ${GREEN}test-hello@${DOMAIN}${NC}"
    echo "  如果你的真实邮箱收到了这封邮件，说明 catch-all 配置成功。"
    echo ""

    echo -e "${CYAN}---------- 注意事项 ----------${NC}"
    echo ""
    echo "  - 某些服务可能会拒绝 catch-all 域名注册（少数情况）"
    echo "  - 建议定期检查邮件转发是否正常工作"
    echo "  - 如果使用 Cloudflare 方案，无需维护服务器"
    echo "  - 如果使用 Postfix 方案，请确保服务器安全和 25 端口可用"
    echo "  - 建议配置 SPF、DKIM、DMARC 记录以提高邮件送达率"
    echo ""

    # 生成几个示例邮箱地址作为演示
    echo -e "${CYAN}---------- 生成示例 ----------${NC}"
    echo ""
    echo "  以下是 5 个随机生成的邮箱地址示例："
    for i in $(seq 1 5); do
        SAMPLE=$(generate_email "$DOMAIN")
        echo -e "    ${GREEN}${SAMPLE}${NC}"
    done
    echo ""

    echo -e "${GREEN}=========================================================${NC}"
    echo -e "${GREEN}  配置完毕，祝你使用愉快！${NC}"
    echo -e "${GREEN}=========================================================${NC}"
    echo ""
}

# ==================== 主流程 ====================
main() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}       Catch-All 邮箱配置工具${NC}"
    echo -e "${CYAN}       用于批量账号注册的域名邮箱全捕获设置${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""

    # ---------- 输入域名 ----------
    prompt_domain

    # ---------- 选择配置模式 ----------
    echo ""
    echo -e "${CYAN}请选择配置模式：${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Cloudflare Email Routing ${GREEN}（推荐，免费，零维护）${NC}"
    echo "     - 利用 Cloudflare 免费邮件路由服务"
    echo "     - 所有邮件转发到你指定的真实邮箱（如 Gmail）"
    echo "     - 无需自建服务器，稳定可靠"
    echo ""
    echo -e "  ${YELLOW}2)${NC} 自建 Postfix 邮件服务器"
    echo "     - 在本机安装 Postfix + Dovecot"
    echo "     - 邮件存储在本地 catchall 用户的 Maildir"
    echo "     - 需要配置 DNS 记录和维护服务器"
    echo ""

    read -rp "$(echo -e "${CYAN}请输入选项 [1/2]：${NC}")" MODE_CHOICE

    case "$MODE_CHOICE" in
        1)
            setup_cloudflare
            ;;
        2)
            setup_postfix
            ;;
        *)
            error "无效选项：${MODE_CHOICE}，请输入 1 或 2"
            ;;
    esac

    # ---------- 验证 Catch-All ----------
    echo ""
    read -rp "$(echo -e "${CYAN}是否立即验证 Catch-All 功能？[y/N]：${NC}")" VERIFY_CHOICE

    case "$VERIFY_CHOICE" in
        [yY]|[yY][eE][sS])
            verify_catchall
            ;;
        *)
            info "跳过验证，你可以稍后手动测试"
            ;;
    esac

    # ---------- 输出总结 ----------
    print_summary
}

# ==================== 入口 ====================
# 支持直接运行脚本，也支持 source 后单独调用 generate_email 函数
# 当脚本被 source 引入时，不会自动执行 main，只导出函数
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
