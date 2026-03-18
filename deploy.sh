#!/bin/bash
set -e

# ============================================================
# API Relay Station - 涓€閿儴缃茶剼鏈?# 鐢ㄩ€旓細鍦ㄥ叏鏂版湇鍔″櫒涓婂揩閫熼儴缃?API 涓户绔欏叏濂楁湇鍔?# 鍖呭惈锛歁ySQL + Redis + New-API + Antigravity Manager + CLIProxyAPI
#       + Cursor API + Kiro2API + Copilot API + WARP + Nginx
# ============================================================

# ----------------------------------------------------------
# 棰滆壊瀹氫箟锛堢敤浜庣粓绔緭鍑虹編鍖栵級
# ----------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ----------------------------------------------------------
# 宸ュ叿鍑芥暟
# ----------------------------------------------------------

# 鎵撳嵃淇℃伅锛堢豢鑹诧級
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# 鎵撳嵃璀﹀憡锛堥粍鑹诧級
warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# 鎵撳嵃閿欒骞堕€€鍑猴紙绾㈣壊锛?error_exit() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# 鎵撳嵃姝ラ鏍囬锛堥潚鑹插姞绮楋級
step() {
    echo ""
    echo -e "${CYAN}${BOLD}========================================${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}========================================${NC}"
}

# ----------------------------------------------------------
# 1. 鎵撳嵃鍚姩妯箙
# ----------------------------------------------------------
echo -e "${CYAN}${BOLD}"
cat << 'BANNER'

     _    ____ ___   ____      _
    / \  |  _ \_ _| |  _ \ ___| | __ _ _   _
   / _ \ | |_) | |  | |_) / _ \ |/ _` | | | |
  / ___ \|  __/| |  |  _ <  __/ | (_| | |_| |
 /_/   \_\_|  |___| |_| \_\___|_|\__,_|\__, |
                                        |___/
  ____  _        _   _
 / ___|| |_ __ _| |_(_) ___  _ __
 \___ \| __/ _` | __| |/ _ \| '_ \
  ___) | || (_| | |_| | (_) | | | |
 |____/ \__\__,_|\__|_|\___/|_| |_|

  ____             _
 |  _ \  ___ _ __ | | ___  _   _  ___ _ __
 | | | |/ _ \ '_ \| |/ _ \| | | |/ _ \ '__|
 | |_| |  __/ |_) | | (_) | |_| |  __/ |
 |____/ \___| .__/|_|\___/ \__, |\___|_|
            |_|            |___/

BANNER
echo -e "${NC}"
echo -e "${BOLD}  API Relay Station - 涓€閿儴缃茶剼鏈?v1.0${NC}"
echo -e "  閮ㄧ讲鏃堕棿: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ----------------------------------------------------------
# 2. 妫€鏌?root 鏉冮檺
# ----------------------------------------------------------
step "妫€鏌ヨ繍琛屾潈闄?

if [[ $EUID -ne 0 ]]; then
    error_exit "姝よ剼鏈繀椤讳互 root 鐢ㄦ埛杩愯锛岃浣跨敤 sudo bash deploy.sh"
fi

info "宸茬‘璁や互 root 鏉冮檺杩愯"

# 璁板綍鑴氭湰鎵€鍦ㄧ洰褰曪紙椤圭洰婧愮爜鐩綍锛?SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info "椤圭洰婧愮爜鐩綍: ${SCRIPT_DIR}"

# ----------------------------------------------------------
# 3. 瀹夎 Docker 鍜?Docker Compose
# ----------------------------------------------------------
step "妫€鏌ュ苟瀹夎 Docker"

# 妫€鏌?Docker 鏄惁宸插畨瑁?if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version 2>/dev/null || echo "unknown")
    info "Docker 宸插畨瑁? ${DOCKER_VERSION}"
else
    warn "Docker 鏈畨瑁咃紝姝ｅ湪閫氳繃瀹樻柟鑴氭湰瀹夎..."

    # 浣跨敤 Docker 瀹樻柟瀹夎鑴氭湰
    if command -v curl &> /dev/null; then
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    elif command -v wget &> /dev/null; then
        wget -qO /tmp/get-docker.sh https://get.docker.com
    else
        error_exit "绯荤粺涓湭鎵惧埌 curl 鎴?wget锛岃鍏堝畨瑁呭叾涓箣涓€"
    fi

    # 鎵ц瀹夎鑴氭湰
    sh /tmp/get-docker.sh || error_exit "Docker 瀹夎澶辫触锛岃妫€鏌ョ綉缁滆繛鎺?
    rm -f /tmp/get-docker.sh

    # 鍚姩 Docker 鏈嶅姟骞惰缃紑鏈鸿嚜鍚?    systemctl start docker || error_exit "Docker 鏈嶅姟鍚姩澶辫触"
    systemctl enable docker || warn "璁剧疆 Docker 寮€鏈鸿嚜鍚け璐ワ紝璇锋墜鍔ㄨ缃?

    info "Docker 瀹夎瀹屾垚"
fi

# 纭繚 Docker 鏈嶅姟姝ｅ湪杩愯
if ! systemctl is-active --quiet docker 2>/dev/null; then
    warn "Docker 鏈嶅姟鏈繍琛岋紝姝ｅ湪鍚姩..."
    systemctl start docker || error_exit "Docker 鏈嶅姟鍚姩澶辫触"
fi

# 妫€鏌?Docker Compose 鎻掍欢鏄惁鍙敤
if docker compose version &> /dev/null; then
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
    info "Docker Compose 鎻掍欢宸插畨瑁? v${COMPOSE_VERSION}"
else
    warn "Docker Compose 鎻掍欢鏈畨瑁咃紝姝ｅ湪瀹夎..."

    # 灏濊瘯閫氳繃鍖呯鐞嗗櫒瀹夎 docker-compose-plugin
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y -qq docker-compose-plugin || true
    elif command -v yum &> /dev/null; then
        yum install -y docker-compose-plugin || true
    elif command -v dnf &> /dev/null; then
        dnf install -y docker-compose-plugin || true
    fi

    # 濡傛灉鍖呯鐞嗗櫒瀹夎澶辫触锛屾墜鍔ㄤ笅杞?    if ! docker compose version &> /dev/null; then
        warn "鍖呯鐞嗗櫒瀹夎澶辫触锛屽皾璇曟墜鍔ㄤ笅杞?Docker Compose 鎻掍欢..."
        COMPOSE_ARCH=$(uname -m)
        # 缁熶竴鏋舵瀯鍚嶇О
        case "${COMPOSE_ARCH}" in
            x86_64)  COMPOSE_ARCH="x86_64" ;;
            aarch64) COMPOSE_ARCH="aarch64" ;;
            armv7l)  COMPOSE_ARCH="armv7" ;;
            *)       error_exit "涓嶆敮鎸佺殑绯荤粺鏋舵瀯: ${COMPOSE_ARCH}" ;;
        esac

        COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}"
        COMPOSE_DEST="/usr/local/lib/docker/cli-plugins/docker-compose"
        mkdir -p /usr/local/lib/docker/cli-plugins
        curl -fsSL "${COMPOSE_URL}" -o "${COMPOSE_DEST}" || error_exit "Docker Compose 涓嬭浇澶辫触"
        chmod +x "${COMPOSE_DEST}"
    fi

    # 鏈€缁堢‘璁?    docker compose version &> /dev/null || error_exit "Docker Compose 瀹夎澶辫触"
    info "Docker Compose 鎻掍欢瀹夎瀹屾垚"
fi

# ----------------------------------------------------------
# 4. 鍒涘缓椤圭洰鐩綍缁撴瀯
# ----------------------------------------------------------
step "鍒涘缓椤圭洰鐩綍缁撴瀯"

PROJECT_DIR="/opt/api-relay"

# 瀹氫箟鎵€鏈夐渶瑕佸垱寤虹殑瀛愮洰褰?DIRECTORIES=(
    "${PROJECT_DIR}"
    "${PROJECT_DIR}/data/antigravity"
    "${PROJECT_DIR}/data/cliproxyapi"
    "${PROJECT_DIR}/data/warp"
    "${PROJECT_DIR}/data/cursor-api"
    "${PROJECT_DIR}/data/copilot-api"
    "${PROJECT_DIR}/data/cursor-register"
    "${PROJECT_DIR}/config/cliproxyapi"
    "${PROJECT_DIR}/config/cursor-api"
    "${PROJECT_DIR}/config/kiro2api"
    "${PROJECT_DIR}/config/cursor-register"
    "${PROJECT_DIR}/nginx"
    "${PROJECT_DIR}/chat-ui"
)

# 閫愪釜鍒涘缓鐩綍
for dir in "${DIRECTORIES[@]}"; do
    if [[ -d "${dir}" ]]; then
        info "鐩綍宸插瓨鍦? ${dir}"
    else
        mkdir -p "${dir}"
        info "宸插垱寤虹洰褰? ${dir}"
    fi
done

# 璁剧疆鍚堢悊鐨勭洰褰曟潈闄?chmod 750 "${PROJECT_DIR}"
info "椤圭洰鏍圭洰褰? ${PROJECT_DIR}"

# ----------------------------------------------------------
# 5. 鐢熸垚 .env 鐜鍙橀噺鏂囦欢
# ----------------------------------------------------------
step "閰嶇疆鐜鍙橀噺"

ENV_FILE="${PROJECT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
    warn ".env 鏂囦欢宸插瓨鍦? ${ENV_FILE}"
    echo -n -e "${YELLOW}鏄惁瑕侀噸鏂扮敓鎴愶紵杩欏皢瑕嗙洊鐜版湁閰嶇疆 [y/N]: ${NC}"
    read -r REGEN_ENV
    if [[ "${REGEN_ENV}" != "y" && "${REGEN_ENV}" != "Y" ]]; then
        info "淇濈暀鐜版湁 .env 鏂囦欢"
        # 浠庣幇鏈?.env 涓鍙栧煙鍚嶏紙鍚庣画 Nginx 閰嶇疆闇€瑕佺敤鍒帮級
        if grep -q "^DOMAIN=" "${ENV_FILE}" 2>/dev/null; then
            DOMAIN=$(grep "^DOMAIN=" "${ENV_FILE}" | cut -d'=' -f2-)
        fi
    else
        # 鐢ㄦ埛閫夋嫨閲嶆柊鐢熸垚锛屾爣璁伴渶瑕佺敓鎴?        GENERATE_ENV=true
    fi
else
    GENERATE_ENV=true
fi

if [[ "${GENERATE_ENV}" == "true" ]]; then
    info "姝ｅ湪鐢熸垚闅忔満瀵嗛挜..."

    # 浣跨敤 openssl 鐢熸垚鍚勭闅忔満瀵嗛挜
    MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)
    SESSION_SECRET=$(openssl rand -hex 32)
    INITIAL_ROOT_TOKEN=$(openssl rand -hex 20)
    ANTIGRAVITY_API_KEY="sk-$(openssl rand -hex 16)"
    CURSOR_API_AUTH_TOKEN=$(openssl rand -hex 16)
    KIRO2API_KEY=$(openssl rand -hex 16)

    info "MySQL Root 瀵嗙爜: 宸茬敓鎴?(32瀛楃鍗佸叚杩涘埗)"
    info "Session Secret: 宸茬敓鎴?(64瀛楃鍗佸叚杩涘埗)"
    info "Root API Token: 宸茬敓鎴?(40瀛楃鍗佸叚杩涘埗)"
    info "Antigravity API Key: 宸茬敓鎴?(sk-xxx 鏍煎紡)"
    info "Cursor API Auth Token: 宸茬敓鎴?(32瀛楃鍗佸叚杩涘埗)"
    info "Kiro2API Key: 宸茬敓鎴?(32瀛楃鍗佸叚杩涘埗)"

    # 浜や簰寮忚幏鍙栫敤鎴峰煙鍚嶉厤缃?    echo ""
    echo -e "${BOLD}璇疯緭鍏ユ偍鐨勫煙鍚嶄俊鎭?${NC}"
    echo -e "  绀轰緥: api.example.com"
    echo -e "  鎻愮ず: 璇风‘淇濊鍩熷悕鐨?DNS 宸茶В鏋愬埌鏈湇鍔″櫒"
    echo ""

    while true; do
        echo -n -e "${CYAN}璇疯緭鍏ュ煙鍚? ${NC}"
        read -r DOMAIN

        # 楠岃瘉鍩熷悕涓嶄负绌?        if [[ -z "${DOMAIN}" ]]; then
            warn "鍩熷悕涓嶈兘涓虹┖锛岃閲嶆柊杈撳叆"
            continue
        fi

        # 绠€鍗曠殑鍩熷悕鏍煎紡楠岃瘉锛堝厑璁稿瓙鍩熷悕鍜岄《绾у煙鍚嶏級
        if [[ ! "${DOMAIN}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
            warn "鍩熷悕鏍煎紡涓嶆纭紝璇疯緭鍏ユ湁鏁堢殑鍩熷悕锛堝 api.example.com锛?
            continue
        fi

        break
    done

    info "鍩熷悕宸茶缃? ${DOMAIN}"

    # 妫€鏌ユ槸鍚︽湁 env.example 妯℃澘鏂囦欢
    if [[ -f "${SCRIPT_DIR}/config/env.example" ]]; then
        info "妫€娴嬪埌 env.example 妯℃澘锛屽熀浜庢ā鏉跨敓鎴?.env 鏂囦欢"
        cp "${SCRIPT_DIR}/config/env.example" "${ENV_FILE}"

        # 浣跨敤 sed 鏇挎崲妯℃澘涓殑鍗犱綅绗?        sed -i "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}|" "${ENV_FILE}"
        sed -i "s|^SESSION_SECRET=.*|SESSION_SECRET=${SESSION_SECRET}|" "${ENV_FILE}"
        sed -i "s|^INITIAL_ROOT_TOKEN=.*|INITIAL_ROOT_TOKEN=${INITIAL_ROOT_TOKEN}|" "${ENV_FILE}"
        sed -i "s|^ANTIGRAVITY_API_KEY=.*|ANTIGRAVITY_API_KEY=${ANTIGRAVITY_API_KEY}|" "${ENV_FILE}"
        sed -i "s|^CURSOR_API_AUTH_TOKEN=.*|CURSOR_API_AUTH_TOKEN=${CURSOR_API_AUTH_TOKEN}|" "${ENV_FILE}"
        sed -i "s|^KIRO2API_KEY=.*|KIRO2API_KEY=${KIRO2API_KEY}|" "${ENV_FILE}"
        sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" "${ENV_FILE}"
    else
        # 娌℃湁妯℃澘鏂囦欢锛屼粠澶寸敓鎴愬畬鏁寸殑 .env
        warn "鏈壘鍒?env.example 妯℃澘锛屽皢鐩存帴鐢熸垚 .env 鏂囦欢"

        cat > "${ENV_FILE}" << ENVEOF
# ============================================================
# API Relay Station 鐜鍙橀噺閰嶇疆
# 鐢?deploy.sh 鑷姩鐢熸垚浜?$(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# ----------------------------------------------------------
# 鍩熷悕閰嶇疆
# ----------------------------------------------------------
DOMAIN=${DOMAIN}

# ----------------------------------------------------------
# MySQL 鏁版嵁搴撻厤缃?# ----------------------------------------------------------
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=new_api
MYSQL_PORT=3306

# ----------------------------------------------------------
# Redis 閰嶇疆
# ----------------------------------------------------------
REDIS_PORT=6379

# ----------------------------------------------------------
# New-API 涓绘湇鍔￠厤缃?# ----------------------------------------------------------
# 浼氳瘽鍔犲瘑瀵嗛挜锛堝姟蹇呬繚瀵嗭級
SESSION_SECRET=${SESSION_SECRET}
# 鍒濆绠＄悊鍛?API Token锛堥娆￠儴缃插悗寤鸿鍦ㄩ潰鏉夸腑閲嶆柊鐢熸垚锛?INITIAL_ROOT_TOKEN=${INITIAL_ROOT_TOKEN}
# New-API 鐩戝惉绔彛
NEW_API_PORT=3000
# 鏁版嵁搴撹繛鎺ュ瓧绗︿覆锛堝鍣ㄥ唴閮ㄧ綉缁滐級
SQL_DSN=root:${MYSQL_ROOT_PASSWORD}@tcp(mysql:3306)/new_api
# Redis 杩炴帴鍦板潃
REDIS_CONN_STRING=redis://redis:6379
# 鍚屾棰戠巼锛堢锛?SYNC_FREQUENCY=60

# ----------------------------------------------------------
# AiClient2Api 鈫?Antigravity Manager 閰嶇疆
# ----------------------------------------------------------
ANTIGRAVITY_API_KEY=${ANTIGRAVITY_API_KEY}
ANTIGRAVITY_WEB_PASSWORD=

# ----------------------------------------------------------
# CLIProxyAPI 閰嶇疆
# ----------------------------------------------------------
CLIPROXYAPI_PORT=8081

# ----------------------------------------------------------
# WARP 浠ｇ悊
# ----------------------------------------------------------
WARP_LICENSE_KEY=

# ----------------------------------------------------------
# Cursor API 閰嶇疆锛坵isdgod/cursor-api锛?# ----------------------------------------------------------
CURSOR_API_AUTH_TOKEN=${CURSOR_API_AUTH_TOKEN}

# ----------------------------------------------------------
# Kiro2API 閰嶇疆锛坈aidaoli/kiro2api锛?# ----------------------------------------------------------
KIRO2API_KEY=${KIRO2API_KEY}

# ----------------------------------------------------------
# Copilot API 閰嶇疆锛坋ricc-ch/copilot-api锛?# ----------------------------------------------------------
COPILOT_GH_TOKEN=

# ----------------------------------------------------------
# Nginx 浠ｇ悊閰嶇疆
# ----------------------------------------------------------
NGINX_HTTP_PORT=80
NGINX_HTTPS_PORT=443
ENVEOF
    fi

    # 淇濇姢 .env 鏂囦欢鏉冮檺锛堜粎 root 鍙鍐欙級
    chmod 600 "${ENV_FILE}"
    info ".env 鏂囦欢宸茬敓鎴? ${ENV_FILE}"
fi

# 纭繚 DOMAIN 鍙橀噺宸茶缃紙鏃犺鏄柊鐢熸垚杩樻槸宸叉湁鐨勶級
if [[ -z "${DOMAIN}" ]]; then
    # 灏濊瘯浠?.env 鏂囦欢涓鍙?    if [[ -f "${ENV_FILE}" ]] && grep -q "^DOMAIN=" "${ENV_FILE}" 2>/dev/null; then
        DOMAIN=$(grep "^DOMAIN=" "${ENV_FILE}" | cut -d'=' -f2-)
    fi

    # 濡傛灉浠嶇劧涓虹┖锛屾彁绀虹敤鎴疯緭鍏?    if [[ -z "${DOMAIN}" ]]; then
        echo -n -e "${CYAN}璇疯緭鍏ュ煙鍚? ${NC}"
        read -r DOMAIN
        [[ -z "${DOMAIN}" ]] && error_exit "鍩熷悕涓嶈兘涓虹┖"
    fi
fi

# 鍔犺浇 .env 鏂囦欢涓殑鎵€鏈夊彉閲忥紙渚涘悗缁剼鏈楠や娇鐢級
set -a
source "${ENV_FILE}"
set +a

# ----------------------------------------------------------
# 6. 澶嶅埗閰嶇疆鏂囦欢鍒伴」鐩洰褰?# ----------------------------------------------------------
step "澶嶅埗椤圭洰閰嶇疆鏂囦欢"

# 澶嶅埗 docker-compose 涓绘枃浠?if [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
    cp "${SCRIPT_DIR}/docker-compose.yml" "${PROJECT_DIR}/docker-compose.yml"
    info "宸插鍒?docker-compose.yml"
else
    warn "鏈壘鍒?docker-compose.yml锛岃纭椤圭洰婧愮爜瀹屾暣"
fi

# 澶嶅埗 docker-compose 鍙嶅悜浠ｇ悊灞傛枃浠?if [[ -f "${SCRIPT_DIR}/docker-compose.reverse.yml" ]]; then
    cp "${SCRIPT_DIR}/docker-compose.reverse.yml" "${PROJECT_DIR}/docker-compose.reverse.yml"
    info "宸插鍒?docker-compose.reverse.yml"
else
    warn "鏈壘鍒?docker-compose.reverse.yml"
fi

# 澶嶅埗 Nginx 閰嶇疆妯℃澘
if [[ -d "${SCRIPT_DIR}/nginx" ]]; then
    cp -r "${SCRIPT_DIR}/nginx/"* "${PROJECT_DIR}/nginx/" 2>/dev/null && \
        info "宸插鍒?nginx 閰嶇疆鐩綍" || \
        warn "nginx 閰嶇疆鐩綍涓虹┖鎴栧鍒跺け璐?
fi

# 澶嶅埗 Chat UI 闈欐€佹枃浠?
if [[ -d "${SCRIPT_DIR}/chat-ui" ]]; then
    cp -r "${SCRIPT_DIR}/chat-ui/"* "${PROJECT_DIR}/chat-ui/" 2>/dev/null && \
        info "宸插鍒?chat-ui 闈欐€侀〉闈?" || \
        warn "chat-ui 鐩綍涓虹┖鎴栧鍒跺け璐?"
fi

# 澶嶅埗 CLIProxyAPI 閰嶇疆妯℃澘
if [[ -d "${SCRIPT_DIR}/config/cliproxyapi" ]]; then
    cp -r "${SCRIPT_DIR}/config/cliproxyapi/"* "${PROJECT_DIR}/config/cliproxyapi/" 2>/dev/null && \
        info "宸插鍒?cliproxyapi 閰嶇疆鏂囦欢" || \
        warn "cliproxyapi 閰嶇疆鐩綍涓虹┖鎴栧鍒跺け璐?
fi

# 澶嶅埗 Cursor API 閰嶇疆妯℃澘
if [[ -d "${SCRIPT_DIR}/config/cursor-api" ]]; then
    cp -r "${SCRIPT_DIR}/config/cursor-api/"* "${PROJECT_DIR}/config/cursor-api/" 2>/dev/null && \
        info "宸插鍒?cursor-api 閰嶇疆鏂囦欢" || \
        warn "cursor-api 閰嶇疆鐩綍涓虹┖鎴栧鍒跺け璐?
fi

# 澶嶅埗 Kiro2API 閰嶇疆妯℃澘
if [[ -d "${SCRIPT_DIR}/config/kiro2api" ]]; then
    cp -r "${SCRIPT_DIR}/config/kiro2api/"* "${PROJECT_DIR}/config/kiro2api/" 2>/dev/null && \
        info "宸插鍒?kiro2api 閰嶇疆鏂囦欢" || \
        warn "kiro2api 閰嶇疆鐩綍涓虹┖鎴栧鍒跺け璐?
fi

# 澶嶅埗 cursor-register 閰嶇疆妯℃澘
if [[ -d "${SCRIPT_DIR}/config/cursor-register" ]]; then
    cp -r "${SCRIPT_DIR}/config/cursor-register/"* "${PROJECT_DIR}/config/cursor-register/" 2>/dev/null && \
        info "宸插鍒?cursor-register 閰嶇疆鏂囦欢" || \
        warn "cursor-register 閰嶇疆鐩綍涓虹┖鎴栧鍒跺け璐?
fi

# 澶嶅埗 cursor-auto-register 婧愮爜锛堢敤浜庢湰鍦版瀯寤洪暅鍍忥級
if [[ -d "${SCRIPT_DIR}/tools/cursor-auto-register" ]]; then
    mkdir -p "${PROJECT_DIR}/tools"
    cp -r "${SCRIPT_DIR}/tools/cursor-auto-register" "${PROJECT_DIR}/tools/" 2>/dev/null && \
        info "宸插鍒?cursor-auto-register 婧愮爜" || \
        warn "cursor-auto-register 婧愮爜澶嶅埗澶辫触"
fi

# 澶嶅埗杈呭姪鑴氭湰
if [[ -d "${SCRIPT_DIR}/scripts" ]]; then
    mkdir -p "${PROJECT_DIR}/scripts"
    cp -r "${SCRIPT_DIR}/scripts/"* "${PROJECT_DIR}/scripts/" 2>/dev/null && \
        info "宸插鍒惰緟鍔╄剼鏈? || \
        warn "杈呭姪鑴氭湰澶嶅埗澶辫触"
    chmod +x "${PROJECT_DIR}/scripts/"*.sh 2>/dev/null
fi

# 澶嶅埗 .env 鏂囦欢鍒伴」鐩洰褰曪紙濡傛灉涓嶅湪鍚屼竴浣嶇疆锛?if [[ "${SCRIPT_DIR}" != "${PROJECT_DIR}" ]]; then
    # .env 宸茬粡鍦?PROJECT_DIR 涓敓鎴愶紝杩欓噷鍙渶纭繚鍏朵粬鍙兘鐨勯厤缃篃澶嶅埗杩囧幓
    # 澶嶅埗鎵€鏈?.yml 鍜?.yaml 鏂囦欢
    for f in "${SCRIPT_DIR}"/*.yml "${SCRIPT_DIR}"/*.yaml; do
        if [[ -f "${f}" ]]; then
            BASENAME=$(basename "${f}")
            # 閬垮厤閲嶅澶嶅埗宸插鐞嗙殑鏂囦欢
            if [[ "${BASENAME}" != "docker-compose.yml" && "${BASENAME}" != "docker-compose.reverse.yml" ]]; then
                cp "${f}" "${PROJECT_DIR}/${BASENAME}"
                info "宸插鍒?${BASENAME}"
            fi
        fi
    done
fi

info "閰嶇疆鏂囦欢澶嶅埗瀹屾垚"

# ----------------------------------------------------------
# 7. 鍚姩鏍稿績鍩虹鏈嶅姟锛圡ySQL + Redis + New-API锛?# ----------------------------------------------------------
step "鍚姩鏍稿績鏈嶅姟 (MySQL + Redis + New-API)"

cd "${PROJECT_DIR}"

# 鍏堟媺鍙栨墍闇€闀滃儚锛堟樉绀鸿繘搴︼級
info "姝ｅ湪鎷夊彇 Docker 闀滃儚锛堥娆″彲鑳借緝鎱紝璇疯€愬績绛夊緟锛?.."
docker compose pull 2>&1 | tail -5 || warn "閮ㄥ垎闀滃儚鎷夊彇鍙兘澶辫触锛屽皢鍦ㄥ惎鍔ㄦ椂閲嶈瘯"

# 鍚姩鏍稿績鏈嶅姟
info "姝ｅ湪鍚姩鏍稿績鏈嶅姟..."
docker compose up -d || error_exit "鏍稿績鏈嶅姟鍚姩澶辫触锛岃妫€鏌?docker-compose.yml 閰嶇疆"

info "鏍稿績鏈嶅姟瀹瑰櫒宸插惎鍔?

# ----------------------------------------------------------
# 8. 绛夊緟 MySQL 灏辩华
# ----------------------------------------------------------
step "绛夊緟 MySQL 鏁版嵁搴撳氨缁?

# 鏈€澶х瓑寰呮椂闂达紙绉掞級
MAX_WAIT=120
WAIT_INTERVAL=3
ELAPSED=0

info "姝ｅ湪绛夊緟 MySQL 瀹屾垚鍒濆鍖栵紙鏈€闀跨瓑寰?${MAX_WAIT} 绉掞級..."

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    # 鏂规硶1锛氶€氳繃 docker compose exec 鎵ц mysqladmin ping
    if docker compose exec -T mysql mysqladmin ping -h localhost \
        --user=root --password="${MYSQL_ROOT_PASSWORD}" &> /dev/null; then
        echo ""
        info "MySQL 宸插氨缁紒(鑰楁椂 ${ELAPSED} 绉?"
        break
    fi

    # 鏂规硶2锛氭鏌ュ鍣ㄥ仴搴风姸鎬侊紙濡傛灉 compose 涓畾涔変簡 healthcheck锛?    HEALTH_STATUS=$(docker compose ps --format json 2>/dev/null | \
        python3 -c "
import sys, json
for line in sys.stdin:
    try:
        obj = json.loads(line)
        if 'mysql' in obj.get('Service','').lower() or 'mysql' in obj.get('Name','').lower():
            print(obj.get('Health','unknown'))
    except: pass
" 2>/dev/null || echo "unknown")

    if [[ "${HEALTH_STATUS}" == "healthy" ]]; then
        echo ""
        info "MySQL 宸插氨缁紙閫氳繃鍋ュ悍妫€鏌ョ‘璁わ級锛?鑰楁椂 ${ELAPSED} 绉?"
        break
    fi

    # 鏄剧ず绛夊緟杩涘害
    echo -n -e "\r${YELLOW}  绛夊緟涓?.. ${ELAPSED}/${MAX_WAIT}s${NC}"
    sleep ${WAIT_INTERVAL}
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

# 妫€鏌ユ槸鍚﹁秴鏃?if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
    echo ""
    warn "MySQL 绛夊緟瓒呮椂锛?{MAX_WAIT}绉掞級锛屽皾璇曠户缁儴缃?.."
    warn "濡傛灉鍚庣画鏈嶅姟鎶ラ敊锛岃鎵嬪姩妫€鏌?MySQL 鐘舵€? docker compose logs mysql"
fi

# ----------------------------------------------------------
# 9. 鍚姩鍙嶅悜浠ｇ悊灞傛湇鍔?# ----------------------------------------------------------
step "鍚姩鍙嶅悜浠ｇ悊灞?(Antigravity + CLIProxy + Cursor + Kiro + Copilot)"

if [[ -f "${PROJECT_DIR}/docker-compose.reverse.yml" ]]; then
    info "姝ｅ湪鎷夊彇鍙嶅悜浠ｇ悊灞傞暅鍍?.."
    docker compose -f docker-compose.reverse.yml pull 2>&1 | tail -5 || \
        warn "閮ㄥ垎闀滃儚鎷夊彇鍙兘澶辫触"

    info "姝ｅ湪鍚姩鍙嶅悜浠ｇ悊灞傛湇鍔?.."
    docker compose -f docker-compose.reverse.yml up -d || \
        error_exit "鍙嶅悜浠ｇ悊灞傛湇鍔″惎鍔ㄥけ璐?

    info "鍙嶅悜浠ｇ悊灞傛湇鍔″凡鍚姩"
else
    warn "鏈壘鍒?docker-compose.reverse.yml锛岃烦杩囧弽鍚戜唬鐞嗗眰閮ㄧ讲"
    warn "鎮ㄥ彲浠ョ◢鍚庢墜鍔ㄩ儴缃插弽鍚戜唬鐞嗗眰"
fi

# ----------------------------------------------------------
# 10. 瀹夎鍜岄厤缃?Nginx
# ----------------------------------------------------------
step "閰嶇疆 Nginx 鍙嶅悜浠ｇ悊"

# 妫€鏌ュ苟瀹夎 Nginx
if command -v nginx &> /dev/null; then
    NGINX_VERSION=$(nginx -v 2>&1 || echo "unknown")
    info "Nginx 宸插畨瑁? ${NGINX_VERSION}"
else
    warn "Nginx 鏈畨瑁咃紝姝ｅ湪瀹夎..."

    # 鏍规嵁涓嶅悓鐨勫寘绠＄悊鍣ㄥ畨瑁?Nginx
    if command -v apt-get &> /dev/null; then
        # Debian / Ubuntu 绯诲垪
        apt-get update -qq
        apt-get install -y -qq nginx || error_exit "Nginx 瀹夎澶辫触"
    elif command -v yum &> /dev/null; then
        # CentOS / RHEL 绯诲垪
        yum install -y epel-release 2>/dev/null || true
        yum install -y nginx || error_exit "Nginx 瀹夎澶辫触"
    elif command -v dnf &> /dev/null; then
        # Fedora / RHEL 8+ 绯诲垪
        dnf install -y nginx || error_exit "Nginx 瀹夎澶辫触"
    elif command -v pacman &> /dev/null; then
        # Arch Linux 绯诲垪
        pacman -Sy --noconfirm nginx || error_exit "Nginx 瀹夎澶辫触"
    else
        error_exit "鏃犳硶纭畾鍖呯鐞嗗櫒锛岃鎵嬪姩瀹夎 Nginx"
    fi

    # 鍚姩 Nginx 骞惰缃紑鏈鸿嚜鍚?    systemctl start nginx || error_exit "Nginx 鍚姩澶辫触"
    systemctl enable nginx || warn "璁剧疆 Nginx 寮€鏈鸿嚜鍚け璐?

    info "Nginx 瀹夎瀹屾垚"
fi

# 纭繚 Nginx 鐩綍缁撴瀯瀛樺湪锛堟煇浜涘彂琛岀増鍙兘娌℃湁 sites-available 鐩綍锛?mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

# 妫€鏌?nginx.conf 鏄惁鍖呭惈 sites-enabled 鐨?include 鎸囦护
if ! grep -q "include.*sites-enabled" /etc/nginx/nginx.conf 2>/dev/null; then
    warn "Nginx 閰嶇疆涓湭鍖呭惈 sites-enabled 鐩綍"
    warn "姝ｅ湪娣诲姞 include 鎸囦护..."

    # 鍦?http 鍧楁湯灏炬坊鍔?include 鎸囦护
    if grep -q "http {" /etc/nginx/nginx.conf; then
        # 鍦?http 鍧楃殑鏈€鍚庝竴涓?} 涔嬪墠鎻掑叆 include 鎸囦护
        sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf 2>/dev/null || \
            warn "鑷姩淇敼 nginx.conf 澶辫触锛岃鎵嬪姩娣诲姞: include /etc/nginx/sites-enabled/*;"
    fi
fi

# 鍑嗗 Nginx 绔欑偣閰嶇疆鏂囦欢
NGINX_CONF_SRC=""
NGINX_CONF_DEST="/etc/nginx/sites-available/api-relay.conf"
NGINX_CONF_LINK="/etc/nginx/sites-enabled/api-relay.conf"

# 鏌ユ壘 Nginx 閰嶇疆妯℃澘锛堟寜浼樺厛绾ф悳绱㈠涓彲鑳界殑浣嶇疆锛?for candidate in \
    "${PROJECT_DIR}/nginx/api.conf" \
    "${PROJECT_DIR}/nginx/api-relay.conf" \
    "${SCRIPT_DIR}/nginx/api.conf" \
    "${SCRIPT_DIR}/nginx/api-relay.conf"; do
    if [[ -f "${candidate}" ]]; then
        NGINX_CONF_SRC="${candidate}"
        break
    fi
done

if [[ -n "${NGINX_CONF_SRC}" ]]; then
    info "浣跨敤 Nginx 閰嶇疆妯℃澘: ${NGINX_CONF_SRC}"

    # 澶嶅埗骞舵浛鎹㈠煙鍚嶅崰浣嶇
    cp "${NGINX_CONF_SRC}" "${NGINX_CONF_DEST}"

    # 鏇挎崲閰嶇疆鏂囦欢涓殑鍩熷悕鍗犱綅绗︼紙鏀寔澶氱甯歌鍗犱綅绗︽牸寮忥級
    sed -i "s/{{DOMAIN}}/${DOMAIN}/g" "${NGINX_CONF_DEST}"
    sed -i "s/\${DOMAIN}/${DOMAIN}/g" "${NGINX_CONF_DEST}"
    sed -i "s/%DOMAIN%/${DOMAIN}/g" "${NGINX_CONF_DEST}"
    sed -i "s/YOUR_DOMAIN/${DOMAIN}/g" "${NGINX_CONF_DEST}"
    sed -i "s/example\.com/${DOMAIN}/g" "${NGINX_CONF_DEST}"
    sed -i "s/server_name _;/server_name ${DOMAIN};/g" "${NGINX_CONF_DEST}"

    info "宸叉浛鎹㈠煙鍚嶄负: ${DOMAIN}"
else
    # 娌℃湁鎵惧埌妯℃澘锛岀敓鎴愰粯璁ょ殑 Nginx 閰嶇疆
    warn "鏈壘鍒?Nginx 閰嶇疆妯℃澘锛屾鍦ㄧ敓鎴愰粯璁ら厤缃?.."

    cat > "${NGINX_CONF_DEST}" << NGINXEOF
# ============================================================
# API Relay Station - Nginx 鍙嶅悜浠ｇ悊閰嶇疆
# 鍩熷悕: ${DOMAIN}
# 鐢?deploy.sh 鑷姩鐢熸垚浜?$(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# HTTP -> HTTPS 閲嶅畾鍚戯紙鍚敤 SSL 鍚庡彇娑堟敞閲婏級
# server {
#     listen 80;
#     listen [::]:80;
#     server_name ${DOMAIN};
#     return 301 https://\$server_name\$request_uri;
# }

# 涓绘湇鍔″櫒鍧楋紙HTTP锛屽惎鐢?SSL 鍓嶄娇鐢級
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # SSL 閰嶇疆锛堜娇鐢?certbot 鑾峰彇璇佷功鍚庡彇娑堟敞閲婏級
    # listen 443 ssl http2;
    # listen [::]:443 ssl http2;
    # ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    # ssl_protocols TLSv1.2 TLSv1.3;
    # ssl_ciphers HIGH:!aNULL:!MD5;
    # ssl_prefer_server_ciphers on;

    # 瀹夊叏澶撮儴
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # 鏃ュ織閰嶇疆
    access_log /var/log/nginx/api-relay-access.log;
    error_log /var/log/nginx/api-relay-error.log;

    # 璇锋眰浣撳ぇ灏忛檺鍒讹紙閫傞厤澶у瀷 API 璇锋眰锛?    client_max_body_size 100m;

    # 浠ｇ悊瓒呮椂璁剧疆锛堥€傞厤闀挎椂闂?AI 鍝嶅簲锛?    proxy_connect_timeout 300s;
    proxy_send_timeout 300s;
    proxy_read_timeout 600s;

    # New-API 涓婚潰鏉匡紙榛樿璺敱锛?    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket 鏀寔锛堢敤浜?SSE 娴佸紡杈撳嚭锛?        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # 绂佺敤缂撳啿锛堢‘淇?SSE 娴佸紡浼犺緭姝ｅ父锛?        proxy_buffering off;
        proxy_cache off;
    }

    # Antigravity Manager 鏈嶅姟璺敱
    location /antigravity/ {
        proxy_pass http://127.0.0.1:9000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_buffering off;
    }

    # CLIProxyAPI 鏈嶅姟璺敱
    location /cliproxyapi/ {
        proxy_pass http://127.0.0.1:9001/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_buffering off;
    }

    # 鍋ュ悍妫€鏌ョ鐐?    location /health {
        access_log off;
        return 200 '{"status":"ok","service":"api-relay"}';
        add_header Content-Type application/json;
    }
}
NGINXEOF

    info "宸茬敓鎴愰粯璁?Nginx 閰嶇疆"
fi

# 鍚敤绔欑偣锛堝垱寤虹鍙烽摼鎺ワ級
if [[ -L "${NGINX_CONF_LINK}" ]]; then
    rm -f "${NGINX_CONF_LINK}"
fi
ln -s "${NGINX_CONF_DEST}" "${NGINX_CONF_LINK}"
info "宸插惎鐢ㄧ珯鐐归厤缃? ${NGINX_CONF_LINK}"

# 绉婚櫎榛樿绔欑偣锛堥伩鍏嶅啿绐侊級
if [[ -L "/etc/nginx/sites-enabled/default" ]]; then
    rm -f /etc/nginx/sites-enabled/default
    info "宸茬Щ闄ら粯璁?Nginx 绔欑偣"
fi

# 娴嬭瘯 Nginx 閰嶇疆璇硶
info "姝ｅ湪楠岃瘉 Nginx 閰嶇疆..."
if nginx -t 2>&1; then
    info "Nginx 閰嶇疆璇硶楠岃瘉閫氳繃"
else
    error_exit "Nginx 閰嶇疆瀛樺湪璇硶閿欒锛岃妫€鏌? ${NGINX_CONF_DEST}"
fi

# 閲嶆柊鍔犺浇 Nginx
info "姝ｅ湪閲嶆柊鍔犺浇 Nginx..."
if systemctl is-active --quiet nginx; then
    systemctl reload nginx || error_exit "Nginx 閲嶆柊鍔犺浇澶辫触"
else
    systemctl start nginx || error_exit "Nginx 鍚姩澶辫触"
fi

info "Nginx 鍙嶅悜浠ｇ悊閰嶇疆瀹屾垚"

# ----------------------------------------------------------
# 11. 閮ㄧ讲瀹屾垚 - 鎵撳嵃鎽樿淇℃伅
# ----------------------------------------------------------
step "閮ㄧ讲瀹屾垚"

# 鑾峰彇鏈嶅姟鍣ㄥ叕缃?IP锛堢敤浜庢樉绀猴級
PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
            echo "<鏈嶅姟鍣↖P>")

# 璇诲彇 .env 涓殑鍏抽敭淇℃伅鐢ㄤ簬鏄剧ず
DISPLAY_TOKEN=$(grep "^INITIAL_ROOT_TOKEN=" "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2- || echo "瑙?.env 鏂囦欢")

echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  API Relay Station 閮ㄧ讲鎴愬姛锛?{NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""
echo -e "${BOLD}  鏈嶅姟璁块棶鍦板潃:${NC}"
echo -e "  -----------------------------------------------"
echo -e "  New-API 绠＄悊闈㈡澘:  ${CYAN}http://${DOMAIN}${NC}"
echo -e "  Chat UI:            ${CYAN}http://${DOMAIN}/chat/${NC}"
echo -e "                     ${CYAN}http://${PUBLIC_IP}${NC}"
echo -e "  Antigravity Mgr:   ${CYAN}http://127.0.0.1:9000${NC} (Web 绠＄悊 + API)"
echo -e "  CLIProxyAPI:       ${CYAN}http://127.0.0.1:9001${NC}"
echo -e "  Cursor API:        ${CYAN}http://127.0.0.1:9002${NC} (Web 绠＄悊 + API)"
echo -e "  Kiro2API:          ${CYAN}http://127.0.0.1:9003${NC}"
echo -e "  Copilot API:       ${CYAN}http://127.0.0.1:9008${NC}"
echo -e "  Cursor Register:   ${CYAN}http://127.0.0.1:9010${NC} (娉ㄥ唽绠＄悊 + Token 鎻愬彇)"
echo -e "  WARP Proxy:        ${CYAN}socks5://127.0.0.1:1080${NC}"
echo -e "  鍋ュ悍妫€鏌?          ${CYAN}http://${DOMAIN}/health${NC}"
echo ""
echo -e "${BOLD}  榛樿鍑嵁:${NC}"
echo -e "  -----------------------------------------------"
echo -e "  New-API 绠＄悊鍛?    鐢ㄦ埛鍚? ${CYAN}root${NC}"
echo -e "                     瀵嗙爜:   ${CYAN}123456${NC} ${RED}(璇风珛鍗充慨鏀癸紒)${NC}"
echo -e "  Root API Token:    ${CYAN}${DISPLAY_TOKEN}${NC}"
echo ""
echo -e "${BOLD}  閲嶈鏂囦欢浣嶇疆:${NC}"
echo -e "  -----------------------------------------------"
echo -e "  椤圭洰鐩綍:          ${CYAN}${PROJECT_DIR}${NC}"
echo -e "  鐜鍙橀噺:          ${CYAN}${ENV_FILE}${NC}"
echo -e "  Nginx 閰嶇疆:        ${CYAN}${NGINX_CONF_DEST}${NC}"
echo -e "  Nginx 鏃ュ織:        ${CYAN}/var/log/nginx/api-relay-*.log${NC}"
echo ""
echo -e "${BOLD}  甯哥敤绠＄悊鍛戒护:${NC}"
echo -e "  -----------------------------------------------"
echo -e "  鏌ョ湅鎵€鏈夋湇鍔＄姸鎬?  ${CYAN}cd ${PROJECT_DIR} && docker compose ps${NC}"
echo -e "  鏌ョ湅鏈嶅姟鏃ュ織:      ${CYAN}cd ${PROJECT_DIR} && docker compose logs -f${NC}"
echo -e "  閲嶅惎鎵€鏈夋湇鍔?      ${CYAN}cd ${PROJECT_DIR} && docker compose restart${NC}"
echo -e "  鍋滄鎵€鏈夋湇鍔?      ${CYAN}cd ${PROJECT_DIR} && docker compose down${NC}"
echo ""
echo -e "${YELLOW}${BOLD}  鎺ヤ笅鏉ユ偍闇€瑕?${NC}"
echo -e "  -----------------------------------------------"
echo -e "  ${YELLOW}1. 閰嶇疆 SSL 璇佷功锛堝己鐑堝缓璁級:${NC}"
echo -e "     ${CYAN}apt install certbot python3-certbot-nginx${NC}"
echo -e "     ${CYAN}certbot --nginx -d ${DOMAIN}${NC}"
echo ""
echo -e "  ${YELLOW}2. 淇敼榛樿瀵嗙爜:${NC}"
echo -e "     鐧诲綍 http://${DOMAIN} 鍚庣珛鍗充慨鏀?root 瀵嗙爜"
echo ""
echo -e "  ${YELLOW}3. 閰嶇疆 OAuth 鐧诲綍锛堝彲閫夛級:${NC}"
echo -e "     鍦?New-API 绠＄悊闈㈡澘 -> 绯荤粺璁剧疆 -> 閰嶇疆鐧诲綍娉ㄥ唽"
echo ""
echo -e "  ${YELLOW}4. 娣诲姞 AI 娓犻亾:${NC}"
echo -e "     鍦?New-API 绠＄悊闈㈡澘 -> 娓犻亾绠＄悊 -> 娣诲姞娓犻亾"
echo -e "     閫嗗悜娓犻亾鍩哄湴鍧€:"
echo -e "       Antigravity:  ${CYAN}http://antigravity-manager:8045${NC}"
echo -e "       CLIProxyAPI:  ${CYAN}http://cliproxyapi:8317${NC}"
echo -e "       Cursor API:   ${CYAN}http://cursor-api:3000${NC}"
echo -e "       Kiro2API:     ${CYAN}http://kiro2api:8080${NC}"
echo -e "       Copilot API:  ${CYAN}http://copilot-api:4141${NC}"
echo ""
echo -e "  ${YELLOW}5. 鑷姩娉ㄥ唽 Cursor 璐﹀彿锛堥渶瑕佸煙鍚嶏級:${NC}"
echo -e "     a. 缂栬緫閭閰嶇疆: ${CYAN}vi ${PROJECT_DIR}/config/cursor-register/.env${NC}"
echo -e "     b. 閲嶅惎娉ㄥ唽鏈嶅姟: ${CYAN}cd ${PROJECT_DIR} && docker compose -f docker-compose.reverse.yml up -d cursor-register${NC}"
echo -e "     c. 杩愯鑷姩鍖栨祦姘寸嚎: ${CYAN}bash ${PROJECT_DIR}/scripts/auto-pipeline.sh${NC}"
echo -e "     d. 鎴栨墜鍔ㄦ帹閫?Token: ${CYAN}bash ${PROJECT_DIR}/scripts/feed-tokens.sh${NC}"
echo ""
echo -e "  ${YELLOW}6. 閰嶇疆闃茬伀澧欙紙濡傛湁闇€瑕侊級:${NC}"
echo -e "     ${CYAN}ufw allow 80/tcp && ufw allow 443/tcp${NC}"
echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  鎰熻阿浣跨敤 API Relay Station锛?{NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""

