#!/bin/bash

# ============================================================
# 账号池管理脚本 - API 中转站
# 使用 SQLite 管理多服务账号（cursor/copilot/windsurf/kiro/gemini）
#
# 用法示例：
#   ./account-manager.sh add --service cursor --email user@test.com --token xxx
#   ./account-manager.sh list --service cursor --status active
#   ./account-manager.sh update 5 --status banned
#   ./account-manager.sh remove 5
#   ./account-manager.sh stats
#   ./account-manager.sh export --service cursor --format env
#   ./account-manager.sh import accounts.csv
#   ./account-manager.sh generate-emails --domain example.com --count 10
#   ./account-manager.sh check --service cursor
#   ./account-manager.sh help
# ============================================================

# ==================== 颜色定义（美化输出） ====================

# 红色：错误信息
RED='\033[0;31m'
# 绿色：成功信息
GREEN='\033[0;32m'
# 黄色：警告信息
YELLOW='\033[1;33m'
# 青色：标题/提示信息
CYAN='\033[0;36m'
# 紫色：强调信息
PURPLE='\033[0;35m'
# 白色加粗：表头
BOLD='\033[1m'
# 重置颜色
NC='\033[0m'

# ==================== 全局配置 ====================

# 数据目录
DATA_DIR="/opt/api-relay/data"

# SQLite 数据库文件路径
DB_FILE="${DATA_DIR}/accounts.db"

# 支持的服务列表
VALID_SERVICES=("cursor" "copilot" "windsurf" "kiro" "gemini")

# 支持的状态列表
VALID_STATUSES=("active" "banned" "expired" "quota_exceeded")

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

# 输出错误日志（不退出）
err() {
    echo -e "${RED}[错误]${NC} $1"
}

# 输出错误日志并退出
die() {
    echo -e "${RED}[错误]${NC} $1"
    exit 1
}

# 输出分隔线
print_separator() {
    echo -e "${CYAN}$(printf '%.0s-' {1..80})${NC}"
}

# 验证服务名称是否有效
validate_service() {
    local service="$1"
    for valid in "${VALID_SERVICES[@]}"; do
        if [[ "${service}" == "${valid}" ]]; then
            return 0
        fi
    done
    err "无效的服务名称: ${service}"
    echo -e "  支持的服务: ${YELLOW}${VALID_SERVICES[*]}${NC}"
    return 1
}

# 验证状态是否有效
validate_status() {
    local status="$1"
    for valid in "${VALID_STATUSES[@]}"; do
        if [[ "${status}" == "${valid}" ]]; then
            return 0
        fi
    done
    err "无效的状态: ${status}"
    echo -e "  支持的状态: ${YELLOW}${VALID_STATUSES[*]}${NC}"
    return 1
}

# 验证 ID 是否为正整数
validate_id() {
    local id="$1"
    if ! [[ "${id}" =~ ^[0-9]+$ ]] || [[ "${id}" -eq 0 ]]; then
        die "无效的账号 ID: ${id}（必须为正整数）"
    fi
}

# 检查某个 ID 是否存在于数据库中
check_id_exists() {
    local id="$1"
    local count
    count=$(sqlite3 "${DB_FILE}" "SELECT COUNT(*) FROM accounts WHERE id = ${id};")
    if [[ "${count}" -eq 0 ]]; then
        die "找不到 ID 为 ${id} 的账号记录"
    fi
}

# 对 SQL 字符串进行转义（防止注入）
sql_escape() {
    local str="$1"
    # 将单引号替换为两个单引号
    echo "${str//\'/\'\'}"
}

# ==================== 依赖检查 ====================

# 检查并安装 sqlite3
check_dependencies() {
    if command -v sqlite3 &> /dev/null; then
        return 0
    fi

    warn "未检测到 sqlite3，正在尝试自动安装..."

    # 尝试使用 apt 安装（Debian/Ubuntu）
    if command -v apt-get &> /dev/null; then
        info "使用 apt-get 安装 sqlite3..."
        sudo apt-get update -y -qq && sudo apt-get install -y -qq sqlite3
        if command -v sqlite3 &> /dev/null; then
            success "sqlite3 安装成功"
            return 0
        fi
    fi

    # 尝试使用 yum 安装（CentOS/RHEL）
    if command -v yum &> /dev/null; then
        info "使用 yum 安装 sqlite3..."
        sudo yum install -y sqlite
        if command -v sqlite3 &> /dev/null; then
            success "sqlite3 安装成功"
            return 0
        fi
    fi

    # 尝试使用 apk 安装（Alpine）
    if command -v apk &> /dev/null; then
        info "使用 apk 安装 sqlite3..."
        sudo apk add sqlite
        if command -v sqlite3 &> /dev/null; then
            success "sqlite3 安装成功"
            return 0
        fi
    fi

    die "无法自动安装 sqlite3，请手动安装后重试！
    Ubuntu/Debian: sudo apt install sqlite3
    CentOS/RHEL:   sudo yum install sqlite
    Alpine:        sudo apk add sqlite"
}

# ==================== 数据库初始化 ====================

# 初始化数据库和表结构
init_database() {
    # 确保数据目录存在
    if [[ ! -d "${DATA_DIR}" ]]; then
        mkdir -p "${DATA_DIR}" 2>/dev/null || sudo mkdir -p "${DATA_DIR}"
        info "已创建数据目录: ${DATA_DIR}"
    fi

    # 创建表（如果不存在）
    sqlite3 "${DB_FILE}" <<'SQL'
CREATE TABLE IF NOT EXISTS accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service TEXT NOT NULL,
    email TEXT NOT NULL,
    password TEXT,
    token TEXT,
    status TEXT DEFAULT 'active',
    models TEXT,
    quota_used INTEGER DEFAULT 0,
    quota_limit INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME,
    notes TEXT
);

-- 为常用查询创建索引
CREATE INDEX IF NOT EXISTS idx_accounts_service ON accounts(service);
CREATE INDEX IF NOT EXISTS idx_accounts_status ON accounts(status);
CREATE INDEX IF NOT EXISTS idx_accounts_email ON accounts(email);

-- 创建更新时间触发器：任何更新操作自动刷新 updated_at 字段
CREATE TRIGGER IF NOT EXISTS trg_accounts_updated_at
    AFTER UPDATE ON accounts
    FOR EACH ROW
    WHEN OLD.updated_at = NEW.updated_at OR NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE accounts SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;
SQL
}

# ==================== 命令：显示横幅 ====================

# 无参数运行时显示的欢迎横幅
show_banner() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}       账号池管理工具 - API 中转站${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "${BOLD}可用命令:${NC}"
    echo ""
    echo -e "  ${GREEN}add${NC}              添加新账号"
    echo -e "  ${GREEN}list${NC}             列出账号（支持筛选）"
    echo -e "  ${GREEN}remove${NC}           删除账号"
    echo -e "  ${GREEN}update${NC}           更新账号字段"
    echo -e "  ${GREEN}stats${NC}            查看统计信息"
    echo -e "  ${GREEN}export${NC}           导出令牌（用于 .env 配置）"
    echo -e "  ${GREEN}import${NC}           从 CSV 文件批量导入"
    echo -e "  ${GREEN}generate-emails${NC}  生成随机邮箱（catch-all 域名）"
    echo -e "  ${GREEN}check${NC}            检查账号有效性"
    echo -e "  ${GREEN}help${NC}             显示帮助信息"
    echo ""
    echo -e "${YELLOW}使用方法:${NC} $0 <命令> [参数]"
    echo -e "${YELLOW}详细帮助:${NC} $0 help"
    echo ""
}

# ==================== 命令：帮助信息 ====================

# 打印详细的使用说明
show_help() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}       账号池管理工具 - 使用帮助${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""

    echo -e "${BOLD}添加账号:${NC}"
    echo -e "  $0 add --service <服务> --email <邮箱> [--password <密码>] [--token <令牌>]"
    echo -e "         [--models <模型列表>] [--quota-limit <配额>] [--expires <过期时间>] [--notes <备注>]"
    echo ""
    echo -e "  ${YELLOW}示例:${NC}"
    echo -e "  $0 add --service cursor --email user@test.com --token work_xxx --models gpt-4,claude-3.5-sonnet"
    echo -e "  $0 add --service copilot --email dev@github.com --token ghp_xxx --expires 2025-12-31"
    echo ""

    echo -e "${BOLD}列出账号:${NC}"
    echo -e "  $0 list [--service <服务>] [--status <状态>]"
    echo ""
    echo -e "  ${YELLOW}示例:${NC}"
    echo -e "  $0 list                        # 列出所有账号"
    echo -e "  $0 list --service cursor        # 只列出 cursor 账号"
    echo -e "  $0 list --status active          # 只列出活跃账号"
    echo -e "  $0 list --service kiro --status banned"
    echo ""

    echo -e "${BOLD}删除账号:${NC}"
    echo -e "  $0 remove <ID>"
    echo ""

    echo -e "${BOLD}更新账号:${NC}"
    echo -e "  $0 update <ID> --<字段> <值>"
    echo ""
    echo -e "  ${YELLOW}可更新字段:${NC} --status, --token, --password, --email, --models,"
    echo -e "             --quota-used, --quota-limit, --expires, --notes, --service"
    echo ""
    echo -e "  ${YELLOW}示例:${NC}"
    echo -e "  $0 update 5 --status banned"
    echo -e "  $0 update 3 --token new_token_value --quota-used 0"
    echo ""

    echo -e "${BOLD}统计信息:${NC}"
    echo -e "  $0 stats"
    echo ""

    echo -e "${BOLD}导出令牌:${NC}"
    echo -e "  $0 export --service <服务> --format env"
    echo ""
    echo -e "  ${YELLOW}输出格式 (env):${NC}"
    echo -e "  CURSOR_AUTH_TOKENS=token1,token2,token3"
    echo -e "  COPILOT_GITHUB_TOKENS=ghp_xxx,ghp_yyy"
    echo ""

    echo -e "${BOLD}批量导入:${NC}"
    echo -e "  $0 import <CSV文件>"
    echo ""
    echo -e "  ${YELLOW}CSV 格式:${NC} service,email,password,token"
    echo -e "  首行如果是表头（含 service 字样）会自动跳过"
    echo ""

    echo -e "${BOLD}生成随机邮箱:${NC}"
    echo -e "  $0 generate-emails --domain <域名> --count <数量>"
    echo ""

    echo -e "${BOLD}检查账号有效性:${NC}"
    echo -e "  $0 check --service <服务>"
    echo ""

    echo -e "${BOLD}支持的服务:${NC} ${VALID_SERVICES[*]}"
    echo -e "${BOLD}支持的状态:${NC} ${VALID_STATUSES[*]}"
    echo ""
}

# ==================== 命令：添加账号 ====================

cmd_add() {
    local service="" email="" password="" token="" models="" quota_limit=0 expires="" notes=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service)
                service="$2"
                shift 2
                ;;
            --email)
                email="$2"
                shift 2
                ;;
            --password)
                password="$2"
                shift 2
                ;;
            --token)
                token="$2"
                shift 2
                ;;
            --models)
                models="$2"
                shift 2
                ;;
            --quota-limit)
                quota_limit="$2"
                shift 2
                ;;
            --expires)
                expires="$2"
                shift 2
                ;;
            --notes)
                notes="$2"
                shift 2
                ;;
            *)
                die "add 命令: 未知参数 '$1'，请使用 '$0 help' 查看帮助"
                ;;
        esac
    done

    # 必填字段校验
    if [[ -z "${service}" ]]; then
        die "add 命令: 缺少必填参数 --service"
    fi
    if [[ -z "${email}" ]]; then
        die "add 命令: 缺少必填参数 --email"
    fi

    # 校验服务名称
    validate_service "${service}" || exit 1

    # 校验邮箱格式（基本检查）
    if ! [[ "${email}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        die "add 命令: 邮箱格式无效: ${email}"
    fi

    # 检查是否已存在相同服务+邮箱的记录
    local existing
    existing=$(sqlite3 "${DB_FILE}" "SELECT COUNT(*) FROM accounts WHERE service = '$(sql_escape "${service}")' AND email = '$(sql_escape "${email}")';")
    if [[ "${existing}" -gt 0 ]]; then
        warn "该服务下已存在相同邮箱的账号: ${service} / ${email}"
        echo -n -e "  是否继续添加？[y/N] "
        read -r confirm
        if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
            info "已取消添加"
            return 0
        fi
    fi

    # 构建过期时间的 SQL 片段
    local expires_sql="NULL"
    if [[ -n "${expires}" ]]; then
        expires_sql="'$(sql_escape "${expires}")'"
    fi

    # 插入数据库
    sqlite3 "${DB_FILE}" "INSERT INTO accounts (service, email, password, token, models, quota_limit, expires_at, notes) VALUES ('$(sql_escape "${service}")', '$(sql_escape "${email}")', '$(sql_escape "${password}")', '$(sql_escape "${token}")', '$(sql_escape "${models}")', ${quota_limit}, ${expires_sql}, '$(sql_escape "${notes}")');"

    # 获取刚插入的 ID
    local new_id
    new_id=$(sqlite3 "${DB_FILE}" "SELECT last_insert_rowid();")

    success "账号添加成功！"
    echo -e "  ${BOLD}ID:${NC}      ${new_id}"
    echo -e "  ${BOLD}服务:${NC}    ${service}"
    echo -e "  ${BOLD}邮箱:${NC}    ${email}"
    if [[ -n "${token}" ]]; then
        # 令牌只显示前8位和后4位，中间用星号替代
        local masked_token
        if [[ ${#token} -gt 12 ]]; then
            masked_token="${token:0:8}****${token: -4}"
        else
            masked_token="****"
        fi
        echo -e "  ${BOLD}令牌:${NC}    ${masked_token}"
    fi
    if [[ -n "${models}" ]]; then
        echo -e "  ${BOLD}模型:${NC}    ${models}"
    fi
    if [[ -n "${expires}" ]]; then
        echo -e "  ${BOLD}过期:${NC}    ${expires}"
    fi
}

# ==================== 命令：列出账号 ====================

cmd_list() {
    local service="" status=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service)
                service="$2"
                shift 2
                ;;
            --status)
                status="$2"
                shift 2
                ;;
            *)
                die "list 命令: 未知参数 '$1'"
                ;;
        esac
    done

    # 如果指定了服务或状态，校验其有效性
    if [[ -n "${service}" ]]; then
        validate_service "${service}" || exit 1
    fi
    if [[ -n "${status}" ]]; then
        validate_status "${status}" || exit 1
    fi

    # 构建 WHERE 条件
    local where_clauses=()
    if [[ -n "${service}" ]]; then
        where_clauses+=("service = '$(sql_escape "${service}")'")
    fi
    if [[ -n "${status}" ]]; then
        where_clauses+=("status = '$(sql_escape "${status}")'")
    fi

    local where_sql=""
    if [[ ${#where_clauses[@]} -gt 0 ]]; then
        where_sql="WHERE $(IFS=" AND "; echo "${where_clauses[*]}")"
    fi

    # 查询数据
    local results
    results=$(sqlite3 -separator '|' "${DB_FILE}" "SELECT id, service, email, status, COALESCE(models, '-'), CASE WHEN quota_limit > 0 THEN quota_used || '/' || quota_limit ELSE '-' END, COALESCE(expires_at, '-') FROM accounts ${where_sql} ORDER BY service, id;")

    # 检查是否有结果
    if [[ -z "${results}" ]]; then
        local filter_msg=""
        [[ -n "${service}" ]] && filter_msg="${filter_msg} 服务=${service}"
        [[ -n "${status}" ]] && filter_msg="${filter_msg} 状态=${status}"
        warn "没有找到匹配的账号记录${filter_msg}"
        return 0
    fi

    # 统计记录数
    local total
    total=$(echo "${results}" | wc -l)

    echo ""
    local filter_desc=""
    [[ -n "${service}" ]] && filter_desc="${filter_desc} ${PURPLE}${service}${NC}"
    [[ -n "${status}" ]] && filter_desc="${filter_desc} ${PURPLE}${status}${NC}"
    if [[ -n "${filter_desc}" ]]; then
        echo -e "${BOLD}账号列表${NC}（筛选:${filter_desc}，共 ${total} 条）:"
    else
        echo -e "${BOLD}账号列表${NC}（共 ${total} 条）:"
    fi
    echo ""

    # 打印表头
    printf "${BOLD}%-6s %-10s %-30s %-16s %-24s %-12s %-12s${NC}\n" \
        "ID" "服务" "邮箱" "状态" "模型" "配额" "过期时间"
    print_separator

    # 逐行输出
    while IFS='|' read -r id svc email stat mdls quota exp; do
        # 根据状态着色
        local status_colored
        case "${stat}" in
            active)         status_colored="${GREEN}${stat}${NC}" ;;
            banned)         status_colored="${RED}${stat}${NC}" ;;
            expired)        status_colored="${YELLOW}${stat}${NC}" ;;
            quota_exceeded) status_colored="${RED}${stat}${NC}" ;;
            *)              status_colored="${stat}" ;;
        esac

        # 截断过长的模型列表
        if [[ ${#mdls} -gt 22 ]]; then
            mdls="${mdls:0:20}.."
        fi

        # 截断过长的邮箱
        if [[ ${#email} -gt 28 ]]; then
            email="${email:0:26}.."
        fi

        printf "%-6s %-10s %-30s %-16b %-24s %-12s %-12s\n" \
            "${id}" "${svc}" "${email}" "${status_colored}" "${mdls}" "${quota}" "${exp}"
    done <<< "${results}"

    echo ""
}

# ==================== 命令：删除账号 ====================

cmd_remove() {
    local id="$1"

    # 参数校验
    if [[ -z "${id}" ]]; then
        die "remove 命令: 缺少账号 ID 参数\n  用法: $0 remove <ID>"
    fi

    validate_id "${id}"
    check_id_exists "${id}"

    # 查询即将删除的记录信息
    local record
    record=$(sqlite3 -separator '|' "${DB_FILE}" "SELECT service, email, status FROM accounts WHERE id = ${id};")
    IFS='|' read -r svc email stat <<< "${record}"

    # 确认删除
    echo -e "即将删除以下账号:"
    echo -e "  ${BOLD}ID:${NC}    ${id}"
    echo -e "  ${BOLD}服务:${NC}  ${svc}"
    echo -e "  ${BOLD}邮箱:${NC}  ${email}"
    echo -e "  ${BOLD}状态:${NC}  ${stat}"
    echo -n -e "${YELLOW}确认删除？[y/N] ${NC}"
    read -r confirm

    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        info "已取消删除"
        return 0
    fi

    # 执行删除
    sqlite3 "${DB_FILE}" "DELETE FROM accounts WHERE id = ${id};"
    success "已删除账号 ID=${id} (${svc}/${email})"
}

# ==================== 命令：更新账号 ====================

cmd_update() {
    local id="$1"
    shift

    # 参数校验
    if [[ -z "${id}" ]]; then
        die "update 命令: 缺少账号 ID 参数\n  用法: $0 update <ID> --<字段> <值>"
    fi

    validate_id "${id}"
    check_id_exists "${id}"

    # 至少需要一个更新字段
    if [[ $# -eq 0 ]]; then
        die "update 命令: 请至少指定一个要更新的字段\n  用法: $0 update <ID> --<字段> <值>"
    fi

    # 收集更新语句
    local set_clauses=()
    local update_desc=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status)
                validate_status "$2" || exit 1
                set_clauses+=("status = '$(sql_escape "$2")'")
                update_desc+=("状态 -> $2")
                shift 2
                ;;
            --token)
                set_clauses+=("token = '$(sql_escape "$2")'")
                update_desc+=("令牌 -> (已更新)")
                shift 2
                ;;
            --password)
                set_clauses+=("password = '$(sql_escape "$2")'")
                update_desc+=("密码 -> (已更新)")
                shift 2
                ;;
            --email)
                set_clauses+=("email = '$(sql_escape "$2")'")
                update_desc+=("邮箱 -> $2")
                shift 2
                ;;
            --service)
                validate_service "$2" || exit 1
                set_clauses+=("service = '$(sql_escape "$2")'")
                update_desc+=("服务 -> $2")
                shift 2
                ;;
            --models)
                set_clauses+=("models = '$(sql_escape "$2")'")
                update_desc+=("模型 -> $2")
                shift 2
                ;;
            --quota-used)
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    die "quota-used 必须为非负整数"
                fi
                set_clauses+=("quota_used = $2")
                update_desc+=("已用配额 -> $2")
                shift 2
                ;;
            --quota-limit)
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    die "quota-limit 必须为非负整数"
                fi
                set_clauses+=("quota_limit = $2")
                update_desc+=("配额上限 -> $2")
                shift 2
                ;;
            --expires)
                set_clauses+=("expires_at = '$(sql_escape "$2")'")
                update_desc+=("过期时间 -> $2")
                shift 2
                ;;
            --notes)
                set_clauses+=("notes = '$(sql_escape "$2")'")
                update_desc+=("备注 -> $2")
                shift 2
                ;;
            *)
                die "update 命令: 未知参数 '$1'"
                ;;
        esac
    done

    # 构建并执行 UPDATE 语句
    local set_sql
    set_sql=$(IFS=", "; echo "${set_clauses[*]}")

    sqlite3 "${DB_FILE}" "UPDATE accounts SET ${set_sql} WHERE id = ${id};"

    success "账号 ID=${id} 已更新:"
    for desc in "${update_desc[@]}"; do
        echo -e "  ${BOLD}-${NC} ${desc}"
    done
}

# ==================== 命令：统计信息 ====================

cmd_stats() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}       账号池统计信息${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""

    # 总账号数
    local total
    total=$(sqlite3 "${DB_FILE}" "SELECT COUNT(*) FROM accounts;")
    echo -e "${BOLD}总账号数:${NC} ${total}"
    echo ""

    # 各服务账号数
    echo -e "${BOLD}按服务分布:${NC}"
    print_separator
    local service_stats
    service_stats=$(sqlite3 -separator '|' "${DB_FILE}" "SELECT service, COUNT(*), SUM(CASE WHEN status='active' THEN 1 ELSE 0 END) FROM accounts GROUP BY service ORDER BY service;")

    if [[ -n "${service_stats}" ]]; then
        printf "  ${BOLD}%-12s %-10s %-10s${NC}\n" "服务" "总数" "活跃"
        while IFS='|' read -r svc cnt active_cnt; do
            printf "  %-12s %-10s ${GREEN}%-10s${NC}\n" "${svc}" "${cnt}" "${active_cnt}"
        done <<< "${service_stats}"
    else
        echo -e "  ${YELLOW}(暂无数据)${NC}"
    fi
    echo ""

    # 各状态账号数
    echo -e "${BOLD}按状态分布:${NC}"
    print_separator
    local status_stats
    status_stats=$(sqlite3 -separator '|' "${DB_FILE}" "SELECT status, COUNT(*) FROM accounts GROUP BY status ORDER BY status;")

    if [[ -n "${status_stats}" ]]; then
        while IFS='|' read -r stat cnt; do
            local color
            case "${stat}" in
                active)         color="${GREEN}" ;;
                banned)         color="${RED}" ;;
                expired)        color="${YELLOW}" ;;
                quota_exceeded) color="${RED}" ;;
                *)              color="${NC}" ;;
            esac
            printf "  ${color}%-18s${NC} %s\n" "${stat}" "${cnt}"
        done <<< "${status_stats}"
    else
        echo -e "  ${YELLOW}(暂无数据)${NC}"
    fi
    echo ""

    # 活跃账号总数
    local active_total
    active_total=$(sqlite3 "${DB_FILE}" "SELECT COUNT(*) FROM accounts WHERE status = 'active';")
    echo -e "${BOLD}活跃账号总数:${NC} ${GREEN}${active_total}${NC}"
    echo ""

    # 模型覆盖情况
    echo -e "${BOLD}模型覆盖情况:${NC}"
    print_separator
    local model_data
    model_data=$(sqlite3 "${DB_FILE}" "SELECT DISTINCT models FROM accounts WHERE models IS NOT NULL AND models != '' AND status = 'active';")

    if [[ -n "${model_data}" ]]; then
        # 收集所有不重复的模型名
        declare -A model_map
        while IFS= read -r model_line; do
            # 按逗号分割
            IFS=',' read -ra model_arr <<< "${model_line}"
            for model in "${model_arr[@]}"; do
                # 去除首尾空格
                model=$(echo "${model}" | xargs)
                if [[ -n "${model}" ]]; then
                    model_map["${model}"]=1
                fi
            done
        done <<< "${model_data}"

        # 排序输出
        local sorted_models
        sorted_models=$(for key in "${!model_map[@]}"; do echo "${key}"; done | sort)
        local model_count=0
        while IFS= read -r m; do
            if [[ -n "${m}" ]]; then
                # 查询有多少活跃账号提供该模型
                local provider_count
                provider_count=$(sqlite3 "${DB_FILE}" "SELECT COUNT(*) FROM accounts WHERE status = 'active' AND models LIKE '%$(sql_escape "${m}")%';")
                printf "  %-35s ${GREEN}%s 个活跃账号${NC}\n" "${m}" "${provider_count}"
                model_count=$((model_count + 1))
            fi
        done <<< "${sorted_models}"
        echo ""
        echo -e "  ${BOLD}共覆盖 ${model_count} 个模型${NC}"
    else
        echo -e "  ${YELLOW}(暂无模型数据)${NC}"
    fi
    echo ""
}

# ==================== 命令：生成随机邮箱 ====================

cmd_generate_emails() {
    local domain="" count=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                domain="$2"
                shift 2
                ;;
            --count)
                count="$2"
                shift 2
                ;;
            *)
                die "generate-emails 命令: 未知参数 '$1'"
                ;;
        esac
    done

    # 必填参数校验
    if [[ -z "${domain}" ]]; then
        die "generate-emails 命令: 缺少必填参数 --domain"
    fi
    if [[ -z "${count}" ]]; then
        die "generate-emails 命令: 缺少必填参数 --count"
    fi

    # 数量校验
    if ! [[ "${count}" =~ ^[0-9]+$ ]] || [[ "${count}" -eq 0 ]]; then
        die "generate-emails 命令: --count 必须为正整数"
    fi
    if [[ "${count}" -gt 1000 ]]; then
        die "generate-emails 命令: 单次生成上限 1000 个"
    fi

    # 域名基本格式校验
    if ! [[ "${domain}" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        die "generate-emails 命令: 域名格式无效: ${domain}"
    fi

    echo ""
    info "正在生成 ${count} 个随机邮箱（域名: ${domain}）..."
    echo ""

    local i=0
    while [[ ${i} -lt ${count} ]]; do
        # 生成8位随机十六进制字符串作为邮箱前缀
        local random_prefix
        if [[ -r /dev/urandom ]]; then
            random_prefix=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
        else
            # 如果 /dev/urandom 不可用，使用 $RANDOM 回退方案
            random_prefix=$(printf '%04x%04x' $RANDOM $RANDOM)
        fi
        echo "${random_prefix}@${domain}"
        i=$((i + 1))
    done

    echo ""
    info "共生成 ${count} 个邮箱地址"
}

# ==================== 命令：导出令牌 ====================

cmd_export() {
    local service="" format=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service)
                service="$2"
                shift 2
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            *)
                die "export 命令: 未知参数 '$1'"
                ;;
        esac
    done

    # 必填参数校验
    if [[ -z "${service}" ]]; then
        die "export 命令: 缺少必填参数 --service"
    fi
    if [[ -z "${format}" ]]; then
        die "export 命令: 缺少必填参数 --format（目前支持: env）"
    fi

    validate_service "${service}" || exit 1

    if [[ "${format}" != "env" ]]; then
        die "export 命令: 不支持的格式 '${format}'（目前仅支持: env）"
    fi

    # 查询所有活跃账号的令牌
    local tokens
    tokens=$(sqlite3 "${DB_FILE}" "SELECT token FROM accounts WHERE service = '$(sql_escape "${service}")' AND status = 'active' AND token IS NOT NULL AND token != '';")

    if [[ -z "${tokens}" ]]; then
        warn "没有找到 ${service} 的活跃令牌"
        return 0
    fi

    # 将多行令牌合并为逗号分隔的字符串
    local token_list
    token_list=$(echo "${tokens}" | paste -sd ',' -)

    # 统计令牌数量
    local token_count
    token_count=$(echo "${tokens}" | wc -l)

    # 根据服务名生成环境变量名
    local env_var_name
    case "${service}" in
        cursor)
            env_var_name="CURSOR_AUTH_TOKENS"
            ;;
        copilot)
            env_var_name="COPILOT_GITHUB_TOKENS"
            ;;
        windsurf)
            env_var_name="WINDSURF_AUTH_TOKENS"
            ;;
        kiro)
            env_var_name="KIRO_AUTH_TOKENS"
            ;;
        gemini)
            env_var_name="GEMINI_AUTH_TOKENS"
            ;;
        *)
            # 回退方案：将服务名大写后拼接 _AUTH_TOKENS
            env_var_name="$(echo "${service}" | tr '[:lower:]' '[:upper:]')_AUTH_TOKENS"
            ;;
    esac

    echo ""
    info "导出 ${service} 服务的活跃令牌（共 ${token_count} 个）:"
    echo ""
    echo "${env_var_name}=${token_list}"
    echo ""
}

# ==================== 命令：批量导入 ====================

cmd_import() {
    local csv_file="$1"

    # 参数校验
    if [[ -z "${csv_file}" ]]; then
        die "import 命令: 缺少 CSV 文件路径参数\n  用法: $0 import <CSV文件>"
    fi

    # 文件存在性检查
    if [[ ! -f "${csv_file}" ]]; then
        die "import 命令: 文件不存在: ${csv_file}"
    fi

    # 文件可读性检查
    if [[ ! -r "${csv_file}" ]]; then
        die "import 命令: 文件无法读取: ${csv_file}"
    fi

    echo ""
    info "正在从 ${csv_file} 导入账号..."
    echo ""

    local success_count=0
    local fail_count=0
    local skip_count=0
    local line_num=0

    while IFS=',' read -r service email password token || [[ -n "${service}" ]]; do
        line_num=$((line_num + 1))

        # 去除首尾空白和可能的 BOM 字符
        service=$(echo "${service}" | tr -d '\r\n' | xargs)
        email=$(echo "${email}" | tr -d '\r\n' | xargs)
        password=$(echo "${password}" | tr -d '\r\n' | xargs)
        token=$(echo "${token}" | tr -d '\r\n' | xargs)

        # 跳过空行
        if [[ -z "${service}" ]]; then
            continue
        fi

        # 跳过表头行（如果包含 "service" 字样）
        if [[ "${service,,}" == "service" ]]; then
            skip_count=$((skip_count + 1))
            continue
        fi

        # 跳过注释行
        if [[ "${service}" == \#* ]]; then
            skip_count=$((skip_count + 1))
            continue
        fi

        # 校验服务名
        local valid_svc=false
        for valid in "${VALID_SERVICES[@]}"; do
            if [[ "${service}" == "${valid}" ]]; then
                valid_svc=true
                break
            fi
        done

        if [[ "${valid_svc}" != "true" ]]; then
            err "第 ${line_num} 行: 无效的服务名称 '${service}'，已跳过"
            fail_count=$((fail_count + 1))
            continue
        fi

        # 校验邮箱
        if [[ -z "${email}" ]]; then
            err "第 ${line_num} 行: 邮箱为空，已跳过"
            fail_count=$((fail_count + 1))
            continue
        fi

        # 插入数据库
        if sqlite3 "${DB_FILE}" "INSERT INTO accounts (service, email, password, token) VALUES ('$(sql_escape "${service}")', '$(sql_escape "${email}")', '$(sql_escape "${password}")', '$(sql_escape "${token}")');" 2>/dev/null; then
            success_count=$((success_count + 1))
        else
            err "第 ${line_num} 行: 插入失败 (${service}/${email})"
            fail_count=$((fail_count + 1))
        fi
    done < "${csv_file}"

    echo ""
    print_separator
    echo -e "${BOLD}导入结果:${NC}"
    echo -e "  ${GREEN}成功:${NC}  ${success_count} 条"
    if [[ ${fail_count} -gt 0 ]]; then
        echo -e "  ${RED}失败:${NC}  ${fail_count} 条"
    fi
    if [[ ${skip_count} -gt 0 ]]; then
        echo -e "  ${YELLOW}跳过:${NC}  ${skip_count} 条（表头/注释）"
    fi
    echo ""
}

# ==================== 命令：检查账号有效性 ====================

cmd_check() {
    local service=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service)
                service="$2"
                shift 2
                ;;
            *)
                die "check 命令: 未知参数 '$1'"
                ;;
        esac
    done

    # 必填参数校验
    if [[ -z "${service}" ]]; then
        die "check 命令: 缺少必填参数 --service"
    fi

    validate_service "${service}" || exit 1

    # 检查 curl 是否可用
    if ! command -v curl &> /dev/null; then
        die "check 命令: 需要 curl 工具，请先安装"
    fi

    # 查询该服务的活跃账号
    local accounts
    accounts=$(sqlite3 -separator '|' "${DB_FILE}" "SELECT id, email, token FROM accounts WHERE service = '$(sql_escape "${service}")' AND status = 'active';")

    if [[ -z "${accounts}" ]]; then
        warn "没有找到 ${service} 的活跃账号"
        return 0
    fi

    local total
    total=$(echo "${accounts}" | wc -l)
    echo ""
    info "正在检查 ${service} 服务的 ${total} 个活跃账号..."
    echo ""

    local ok_count=0
    local fail_count=0

    # 根据不同服务确定检测端点和方式
    local check_url="" check_port=""
    case "${service}" in
        cursor)
            check_url="http://127.0.0.1:9002/health"
            check_port=9002
            ;;
        copilot)
            check_url="http://127.0.0.1:9008/health"
            check_port=9008
            ;;
        windsurf)
            check_url="http://127.0.0.1:9004/health"
            check_port=9004
            ;;
        kiro)
            # Kiro (AWS) 没有本地代理端点，仅检查令牌非空
            check_url=""
            ;;
        gemini)
            # Gemini 没有本地代理端点，仅检查令牌非空
            check_url=""
            ;;
    esac

    while IFS='|' read -r id email token; do
        echo -n -e "  检查 ID=${id} (${email})... "

        # 基本检查：令牌是否非空
        if [[ -z "${token}" ]]; then
            echo -e "${RED}失败${NC} - 令牌为空"
            sqlite3 "${DB_FILE}" "UPDATE accounts SET status = 'expired' WHERE id = ${id};"
            fail_count=$((fail_count + 1))
            continue
        fi

        # 如果有本地检测端点，尝试发起连接检查
        if [[ -n "${check_url}" ]]; then
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${check_url}" 2>/dev/null)

            if [[ "${http_code}" -ge 200 ]] && [[ "${http_code}" -lt 400 ]] 2>/dev/null; then
                echo -e "${GREEN}正常${NC} - 服务端点可达 (HTTP ${http_code})"
                ok_count=$((ok_count + 1))
            else
                # 端点不可达不一定是账号问题，可能是服务未启动
                echo -e "${YELLOW}未知${NC} - 服务端点不可达 (HTTP ${http_code:-无响应})"
                ok_count=$((ok_count + 1))  # 不因服务未启动而标记账号失效
            fi
        else
            # 无检测端点时，令牌非空视为有效
            echo -e "${GREEN}正常${NC} - 令牌存在"
            ok_count=$((ok_count + 1))
        fi
    done <<< "${accounts}"

    echo ""
    print_separator
    echo -e "${BOLD}检查结果:${NC}"
    echo -e "  ${GREEN}正常:${NC}  ${ok_count} 个"
    if [[ ${fail_count} -gt 0 ]]; then
        echo -e "  ${RED}失效:${NC}  ${fail_count} 个（已自动更新状态为 expired）"
    fi
    echo ""
}

# ==================== 主入口 ====================

main() {
    # 检查依赖
    check_dependencies

    # 初始化数据库
    init_database

    # 获取子命令
    local command="${1:-}"

    # 无参数时显示横幅
    if [[ -z "${command}" ]]; then
        show_banner
        exit 0
    fi

    # 移除子命令参数，将剩余参数传递给子命令函数
    shift

    # 分发到对应的子命令处理函数
    case "${command}" in
        add)
            cmd_add "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        remove)
            cmd_remove "$@"
            ;;
        update)
            cmd_update "$@"
            ;;
        stats)
            cmd_stats
            ;;
        generate-emails)
            cmd_generate_emails "$@"
            ;;
        export)
            cmd_export "$@"
            ;;
        import)
            cmd_import "$@"
            ;;
        check)
            cmd_check "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            err "未知命令: ${command}"
            echo ""
            echo -e "使用 ${YELLOW}$0 help${NC} 查看可用命令"
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
