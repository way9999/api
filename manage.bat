@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

:: ============================================================
:: 渡屿AI Gateway — 服务管理脚本
:: 用法: manage.bat [命令] [参数]
:: ============================================================

cd /d "%~dp0"

set "COMPOSE_CORE=docker compose -f docker-compose.yml"
set "COMPOSE_REVERSE=docker compose -f docker-compose.reverse.yml"
set "COMPOSE_CADDY=docker compose -f docker-compose.caddy.yml"
set "COMPOSE_TUNNEL=docker compose -f docker-compose.tunnel.yml"

if "%1"=="" goto usage
if "%1"=="start" goto start
if "%1"=="stop" goto stop
if "%1"=="restart" goto restart
if "%1"=="status" goto status
if "%1"=="logs" goto logs
if "%1"=="update" goto update
if "%1"=="build" goto build
if "%1"=="help" goto usage
goto usage

:: ==================== start ====================
:start
echo 启动渡屿AI Gateway ...
echo.

echo [1/3] 启动核心服务（MySQL + Redis + New API）...
%COMPOSE_CORE% up -d

echo 等待 MySQL 就绪...
set /a count=0
:start_wait_mysql
if !count! geq 12 (
    echo [警告] MySQL 健康检查超时，继续启动...
    goto start_mysql_done
)
timeout /t 5 /nobreak >nul
docker inspect --format="{{.State.Health.Status}}" api-mysql 2>nul | findstr "healthy" >nul
if %errorlevel% neq 0 (
    set /a count+=1
    goto start_wait_mysql
)
echo MySQL 已就绪 ✓
:start_mysql_done

echo [2/3] 启动逆向代理层...
%COMPOSE_REVERSE% up -d

echo [3/3] 启动 Caddy 反向代理...
%COMPOSE_CADDY% up -d

:: 检查是否有 Tunnel Token
for /f "tokens=1,* delims==" %%a in ('findstr "^CF_TUNNEL_TOKEN=" .env 2^>nul') do set "CF_TOKEN=%%b"
if not "!CF_TOKEN!"=="" (
    if not "!CF_TOKEN!"==" " (
        echo 启动 Cloudflare Tunnel...
        %COMPOSE_TUNNEL% up -d
    )
)

echo.
echo 所有服务已启动 ✓
echo 使用 manage.bat status 查看运行状态
goto end

:: ==================== stop ====================
:stop
echo 停止渡屿AI Gateway ...
echo.

:: 先停 tunnel（如果存在）
docker ps -q --filter "name=api-cloudflared" >nul 2>&1 && (
    echo 停止 Cloudflare Tunnel...
    %COMPOSE_TUNNEL% down 2>nul
)

echo 停止 Caddy...
%COMPOSE_CADDY% down

echo 停止逆向代理层...
%COMPOSE_REVERSE% down

echo 停止核心服务...
%COMPOSE_CORE% down

echo.
echo 所有服务已停止 ✓
goto end

:: ==================== restart ====================
:restart
echo 重启渡屿AI Gateway ...
echo.
call :stop
echo.
call :start
goto end

:: ==================== status ====================
:status
echo.
echo ╔══════════════════════════════════════════╗
echo ║     渡屿AI Gateway — 服务状态            ║
echo ╚══════════════════════════════════════════╝
echo.
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" --filter "network=api-relay_api-network" 2>nul
echo.

:: 显示访问地址
for /f "tokens=1,* delims==" %%a in ('findstr "^MAIN_DOMAIN=" .env 2^>nul') do set "SHOW_DOMAIN=%%b"
if not "!SHOW_DOMAIN!"=="" if not "!SHOW_DOMAIN!"=="localhost" (
    echo 访问地址: https://!SHOW_DOMAIN!
) else (
    echo 访问地址: http://localhost
)
echo.
goto end

:: ==================== logs ====================
:logs
if "%2"=="" (
    echo 用法: manage.bat logs [服务名]
    echo.
    echo 可用服务:
    echo   核心层:   mysql, redis, new-api
    echo   代理层:   antigravity-manager, cliproxyapi, cursor-api,
    echo             kiro2api, kirocli2api, copilot-api, codex-proxy,
    echo             gpt-register, gpt-manager, cursor-register, resin
    echo   网关层:   caddy
    echo   隧道:     cloudflared
    echo.
    echo 示例: manage.bat logs caddy
    echo       manage.bat logs new-api
    goto end
)

:: 根据服务名确定 compose 文件
set "SVC=%2"
if "%SVC%"=="mysql" ( %COMPOSE_CORE% logs -f --tail 100 mysql & goto end )
if "%SVC%"=="redis" ( %COMPOSE_CORE% logs -f --tail 100 redis & goto end )
if "%SVC%"=="new-api" ( %COMPOSE_CORE% logs -f --tail 100 new-api & goto end )
if "%SVC%"=="caddy" ( %COMPOSE_CADDY% logs -f --tail 100 caddy & goto end )
if "%SVC%"=="cloudflared" ( %COMPOSE_TUNNEL% logs -f --tail 100 cloudflared & goto end )

:: 其他服务都在 reverse compose 中
%COMPOSE_REVERSE% logs -f --tail 100 %SVC%
goto end

:: ==================== update ====================
:update
echo 更新渡屿AI Gateway ...
echo.

echo [1/4] 拉取最新镜像...
%COMPOSE_CORE% pull
%COMPOSE_REVERSE% pull
%COMPOSE_CADDY% pull

echo [2/4] 重新构建本地镜像...
%COMPOSE_REVERSE% build --parallel
%COMPOSE_CADDY% build

echo [3/4] 重启服务...
call :stop
echo.
call :start

echo [4/4] 清理旧镜像...
docker image prune -f >nul 2>&1

echo.
echo 更新完成 ✓
goto end

:: ==================== build ====================
:build
echo 重新构建本地镜像 ...
echo.

echo 构建逆向代理层镜像（kirocli2api, codex-proxy, gpt-register, cursor-register）...
%COMPOSE_REVERSE% build --parallel --no-cache

echo 构建 Caddy 自定义镜像...
%COMPOSE_CADDY% build --no-cache

echo.
echo 构建完成 ✓
echo 使用 manage.bat restart 重启服务以应用新镜像
goto end

:: ==================== usage ====================
:usage
echo.
echo 渡屿AI Gateway — 服务管理工具
echo.
echo 用法: manage.bat [命令]
echo.
echo 命令:
echo   start     启动全部服务
echo   stop      停止全部服务
echo   restart   重启全部服务
echo   status    查看容器运行状态
echo   logs      查看服务日志 (manage.bat logs [服务名])
echo   update    拉取最新镜像并重启
echo   build     重新构建本地镜像
echo   help      显示此帮助信息
echo.
goto end

:end
endlocal
