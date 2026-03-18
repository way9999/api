#!/bin/bash
set -e

# ============================================================
# 数据库与配置备份脚本
# 适用于 cron 定时任务: 0 3 * * * /opt/api-relay/scripts/backup.sh
# 每天凌晨3点自动执行备份，保留最近7天的备份
# ============================================================

# ---------- 基础配置 ----------

# 项目根目录
PROJECT_DIR="/opt/api-relay"

# 备份根目录
BACKUP_ROOT="/opt/api-relay/backups"

# 当前日期，用于创建带日期戳的子目录
DATE_STAMP=$(date +"%Y%m%d_%H%M%S")

# 本次备份的目标目录
BACKUP_DIR="${BACKUP_ROOT}/${DATE_STAMP}"

# 最终压缩包路径
ARCHIVE_FILE="${BACKUP_ROOT}/backup_${DATE_STAMP}.tar.gz"

# 备份保留天数
RETENTION_DAYS=7

# 日志输出函数（cron 环境下也能记录时间）
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ---------- 前置检查 ----------

# 检查 .env 文件是否存在
if [ ! -f "${PROJECT_DIR}/.env" ]; then
    log "错误: 找不到 .env 文件 (${PROJECT_DIR}/.env)，备份终止"
    exit 1
fi

# 从 .env 文件中读取 MySQL root 密码
MYSQL_ROOT_PASSWORD=$(grep -E '^MYSQL_ROOT_PASSWORD=' "${PROJECT_DIR}/.env" | cut -d '=' -f2- | tr -d '"' | tr -d "'")

if [ -z "${MYSQL_ROOT_PASSWORD}" ]; then
    log "错误: 无法从 .env 文件中读取 MYSQL_ROOT_PASSWORD，备份终止"
    exit 1
fi

# 创建备份目录（如果不存在则自动创建）
mkdir -p "${BACKUP_DIR}"
log "备份目录已创建: ${BACKUP_DIR}"

# ---------- 1. 备份 MySQL 数据库 ----------

log "开始备份 MySQL 数据库..."

# 使用 docker exec 执行 mysqldump，导出全部数据库
# --single-transaction: 保证 InnoDB 表的一致性快照，不锁表
# --routines: 导出存储过程和函数
# --triggers: 导出触发器
# --events: 导出事件调度器
docker exec mysql mysqldump \
    -uroot \
    -p"${MYSQL_ROOT_PASSWORD}" \
    --all-databases \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    > "${BACKUP_DIR}/mysql_all_databases.sql"

# 检查 mysqldump 是否成功
if [ $? -eq 0 ]; then
    log "MySQL 数据库备份成功"
else
    log "错误: MySQL 数据库备份失败"
    exit 1
fi

# ---------- 2. 备份 Redis RDB 文件 ----------

log "开始备份 Redis 数据..."

# 先触发 Redis 的 BGSAVE，确保 RDB 文件是最新的
docker exec redis redis-cli BGSAVE > /dev/null 2>&1

# 等待 BGSAVE 完成（最多等待60秒）
WAIT_COUNT=0
MAX_WAIT=60
while [ ${WAIT_COUNT} -lt ${MAX_WAIT} ]; do
    # 检查后台保存是否仍在进行
    BG_STATUS=$(docker exec redis redis-cli LASTSAVE 2>/dev/null)
    sleep 2
    BG_STATUS_NEW=$(docker exec redis redis-cli LASTSAVE 2>/dev/null)

    if [ "${BG_STATUS}" != "${BG_STATUS_NEW}" ] || [ ${WAIT_COUNT} -gt 5 ]; then
        # LASTSAVE 时间戳发生变化，说明保存完成；或者已经等了足够久
        break
    fi

    WAIT_COUNT=$((WAIT_COUNT + 2))
done

# 从 Redis 容器中复制 RDB 文件到备份目录
# 默认 RDB 文件路径为 /data/dump.rdb
docker cp redis:/data/dump.rdb "${BACKUP_DIR}/redis_dump.rdb" 2>/dev/null

if [ $? -eq 0 ]; then
    log "Redis RDB 文件备份成功"
else
    log "警告: Redis RDB 文件备份失败（可能文件不存在或容器未运行）"
    # Redis 备份失败不终止整体备份流程
fi

# ---------- 3. 备份配置文件 ----------

log "开始备份配置文件..."

# 创建配置文件备份子目录
mkdir -p "${BACKUP_DIR}/config_files"

# 备份 .env 环境配置文件
if [ -f "${PROJECT_DIR}/.env" ]; then
    cp "${PROJECT_DIR}/.env" "${BACKUP_DIR}/config_files/.env"
    log "已备份 .env 文件"
else
    log "警告: .env 文件不存在，跳过"
fi

# 备份 config/ 目录（应用配置）
if [ -d "${PROJECT_DIR}/config/" ]; then
    cp -r "${PROJECT_DIR}/config/" "${BACKUP_DIR}/config_files/config/"
    log "已备份 config/ 目录"
else
    log "警告: config/ 目录不存在，跳过"
fi

# 备份 nginx/ 目录（Nginx 配置）
if [ -d "${PROJECT_DIR}/nginx/" ]; then
    cp -r "${PROJECT_DIR}/nginx/" "${BACKUP_DIR}/config_files/nginx/"
    log "已备份 nginx/ 目录"
else
    log "警告: nginx/ 目录不存在，跳过"
fi

# ---------- 4. 压缩备份文件 ----------

log "开始压缩备份文件..."

# 使用 tar 将备份目录压缩为 .tar.gz 归档文件
# -C 切换到备份根目录，只打包日期子目录，保持路径简洁
tar -czf "${ARCHIVE_FILE}" -C "${BACKUP_ROOT}" "${DATE_STAMP}"

if [ $? -eq 0 ]; then
    log "备份压缩成功: ${ARCHIVE_FILE}"

    # 压缩完成后删除未压缩的备份目录，节省磁盘空间
    rm -rf "${BACKUP_DIR}"
    log "已清理未压缩的临时备份目录"
else
    log "错误: 备份压缩失败"
    exit 1
fi

# ---------- 5. 清理过期备份 ----------

log "开始清理 ${RETENTION_DAYS} 天前的旧备份..."

# 查找并删除超过保留天数的备份压缩包
DELETED_COUNT=0
while IFS= read -r OLD_BACKUP; do
    rm -f "${OLD_BACKUP}"
    log "已删除过期备份: ${OLD_BACKUP}"
    DELETED_COUNT=$((DELETED_COUNT + 1))
done < <(find "${BACKUP_ROOT}" -name "backup_*.tar.gz" -type f -mtime +${RETENTION_DAYS})

# 同时清理可能残留的旧备份目录
while IFS= read -r OLD_DIR; do
    rm -rf "${OLD_DIR}"
    log "已删除过期备份目录: ${OLD_DIR}"
    DELETED_COUNT=$((DELETED_COUNT + 1))
done < <(find "${BACKUP_ROOT}" -maxdepth 1 -type d -mtime +${RETENTION_DAYS} ! -path "${BACKUP_ROOT}")

if [ ${DELETED_COUNT} -eq 0 ]; then
    log "没有需要清理的过期备份"
else
    log "共清理 ${DELETED_COUNT} 个过期备份"
fi

# ---------- 6. 输出备份摘要 ----------

# 获取备份文件大小（人类可读格式）
BACKUP_SIZE=$(du -sh "${ARCHIVE_FILE}" | cut -f1)

log "=========================================="
log "备份完成！"
log "备份文件: ${ARCHIVE_FILE}"
log "备份大小: ${BACKUP_SIZE}"
log "保留策略: 最近 ${RETENTION_DAYS} 天"
log "=========================================="

# 列出当前所有备份文件
log "当前备份列表:"
ls -lh "${BACKUP_ROOT}"/backup_*.tar.gz 2>/dev/null | while read -r line; do
    log "  ${line}"
done

exit 0
