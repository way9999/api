#!/bin/bash
# ============================================================
# xy123.me Nginx 反代 + SSL 一键配置脚本
# 在服务器上执行: bash setup-nginx.sh
# ============================================================
set -e

DOMAIN="xy123.me"
VHOST_DIR="/www/server/nginx/conf/vhost"
NGINX_CONF="/www/server/nginx/conf/nginx.conf"
CONF_FILE="${VHOST_DIR}/${DOMAIN}.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "请以 root 运行: sudo bash setup-nginx.sh"

echo -e "${CYAN}=== 配置 ${DOMAIN} Nginx 反代 ===${NC}"

# 1. 创建 vhost 目录
mkdir -p "${VHOST_DIR}"
info "vhost 目录就绪"

# 2. 写入 Nginx 配置
cat > "${CONF_FILE}" << 'NGINX'
server {
    listen 80;
    server_name xy123.me;

    client_max_body_size 100m;

    access_log /var/log/nginx/xy123_access.log;
    error_log  /var/log/nginx/xy123_error.log;

    location = /chat {
        return 302 /chat/;
    }

    location ^~ /chat/ {
        alias /opt/api/chat-ui/;
        try_files $uri $uri/ /chat/index.html;
        expires 1h;
        add_header Cache-Control "public, no-transform";
    }

    location = / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        sub_filter '</body>' '<script src="/chat/home-entry.js"></script></body>';
        sub_filter_once on;
        sub_filter_types text/html;
    }

    location /v1/responses {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection '';
        proxy_http_version 1.1;
        chunked_transfer_encoding on;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        tcp_nodelay on;
        proxy_request_buffering off;
        keepalive_timeout 620s;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection '';
        proxy_http_version 1.1;
        chunked_transfer_encoding on;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
NGINX
info "Nginx 站点配置已写入 ${CONF_FILE}"

# 3. 确保 nginx.conf 加载 vhost 目录
if ! grep -q "include.*vhost" "${NGINX_CONF}" 2>/dev/null; then
    # 在 http 块的最后一个 } 之前插入 include
    sed -i '/^http/,/^}/{
        /^}/ i\    include /www/server/nginx/conf/vhost/*.conf;
    }' "${NGINX_CONF}"
    info "已在 nginx.conf 中添加 vhost include"
else
    info "nginx.conf 已包含 vhost include，跳过"
fi

# 4. 测试配置
nginx -t || error "Nginx 配置测试失败，请检查"
info "Nginx 配置测试通过"

# 5. 重载 Nginx
nginx -s reload
info "Nginx 已重载"

# 6. 安装 certbot 并申请 SSL
echo ""
echo -e "${CYAN}=== 申请 SSL 证书 ===${NC}"

if ! command -v certbot &>/dev/null; then
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq certbot python3-certbot-nginx
    elif command -v yum &>/dev/null; then
        yum install -y epel-release
        yum install -y certbot python3-certbot-nginx
    fi
fi

if command -v certbot &>/dev/null; then
    certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email --redirect
    info "SSL 证书已申请并配置完成"
else
    echo -e "${RED}certbot 安装失败，请手动安装后运行:${NC}"
    echo "  certbot --nginx -d ${DOMAIN}"
fi

# 7. 完成
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  配置完成！${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  访问地址: ${CYAN}https://${DOMAIN}${NC}"
echo -e "  管理面板: ${CYAN}https://${DOMAIN}${NC}"
echo -e "  Chat UI:  ${CYAN}https://${DOMAIN}/chat/${NC}"
echo -e "  API 端点: ${CYAN}https://${DOMAIN}/v1/${NC}"
echo ""
echo -e "  默认账号: ${CYAN}root${NC} / ${CYAN}123456${NC} ${RED}(请立即修改！)${NC}"
echo ""
