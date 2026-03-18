#!/bin/bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/api-relay}"
SOURCE_DIR="${1:-$(pwd)}"

if [[ ! -d "${SOURCE_DIR}/chat-ui" ]]; then
  echo "[ERROR] chat-ui 目录不存在: ${SOURCE_DIR}/chat-ui" >&2
  exit 1
fi

if [[ ! -f "${SOURCE_DIR}/nginx/api.conf" ]]; then
  echo "[ERROR] nginx/api.conf 不存在: ${SOURCE_DIR}/nginx/api.conf" >&2
  exit 1
fi

mkdir -p "${PROJECT_DIR}/chat-ui"
mkdir -p "${PROJECT_DIR}/nginx"

cp -f "${SOURCE_DIR}/chat-ui/"* "${PROJECT_DIR}/chat-ui/"
cp -f "${SOURCE_DIR}/nginx/api.conf" "${PROJECT_DIR}/nginx/api.conf"

if [[ -f "${SOURCE_DIR}/deploy.sh" ]]; then
  cp -f "${SOURCE_DIR}/deploy.sh" "${PROJECT_DIR}/deploy.sh"
fi

cp -f "${PROJECT_DIR}/nginx/api.conf" /etc/nginx/sites-available/api-relay.conf
ln -sfn /etc/nginx/sites-available/api-relay.conf /etc/nginx/sites-enabled/api-relay.conf

nginx -t
systemctl reload nginx

echo "[OK] Chat UI 已部署到 ${PROJECT_DIR}/chat-ui，并已重载 Nginx"
echo "[OK] 访问地址: /chat/"
