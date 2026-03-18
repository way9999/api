#!/bin/bash
# 覆盖宝塔 Nginx 配置，反代 xy123.me → New API
set -e

CONF="/www/server/panel/vhost/nginx/xy123.me.conf"

[[ $EUID -ne 0 ]] && echo "请用 sudo 运行" && exit 1

cp "$CONF" "${CONF}.bak"

cat > "$CONF" << 'NGINXCONF'
server
{
    listen 80;
    server_name xy123.me;
    client_max_body_size 100m;

    include /www/server/panel/vhost/nginx/well-known/xy123.me.conf;

    location ~ \.well-known{
        allow all;
    }

    location = /chat {
        return 302 /chat/;
    }

    location ^~ /chat/ {
        alias /opt/api/chat-ui/;
        try_files $uri $uri/ /chat/index.html;
    }

    location = / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /v1/responses {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection '';
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection '';
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    access_log /www/wwwlogs/xy123.me.log;
    error_log /www/wwwlogs/xy123.me.error.log;
}
NGINXCONF

nginx -t && nginx -s reload
echo "搞定！访问 http://xy123.me 试试"
