@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

:: ============================================================
:: 渡屿AI Gateway — Windows 一键部署脚本
:: 适用于全新 Windows 11 云服务器
:: ============================================================

title 渡屿AI Gateway 部署工具

echo.
echo  ╔══════════════════════════════════════════╗
echo  ║     渡屿AI Gateway — Windows 部署工具     ║
echo  ╚══════════════════════════════════════════╝
echo.

:: 切换到脚本所在目录
cd /d "%~dp0"

:: ==================== 第1步：检测 Docker Desktop ====================
echo [1/8] 检测 Docker Desktop ...
docker info >nul 2>&1
if %errorlevel% neq 0 (
    echo   Docker 未运行，正在检测安装状态...
    where docker >nul 2>&1
    if %errorlevel% neq 0 (
        echo   Docker Desktop 未安装，正在通过 winget 安装...
        winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
        if %errorlevel% neq 0 (
            echo   [错误] Docker Desktop 安装失败，请手动安装后重试。
            echo   下载地址: https://www.docker.com/products/docker-desktop/
            pause
            exit /b 1
        )
        echo.
        echo   Docker Desktop 已安装，请手动启动 Docker Desktop 后重新运行此脚本。
        echo   首次启动需要完成 WSL2 初始化，可能需要重启电脑。
        pause
        exit /b 0
    ) else (
        echo   Docker 已安装但未运行，请启动 Docker Desktop ...
        start "" "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    )

    echo   等待 Docker Engine 就绪（最多等待 120 秒）...
    set /a count=0
    :wait_docker
    if !count! geq 24 (
        echo   [错误] Docker Engine 启动超时，请确认 Docker Desktop 已正常运行。
        pause
        exit /b 1
    )
    timeout /t 5 /nobreak >nul
    docker info >nul 2>&1
    if %errorlevel% neq 0 (
        set /a count+=1
        echo     等待中... (!count!/24)
        goto wait_docker
    )
)
echo   Docker Engine 已就绪 ✓
echo.

:: ==================== 第2步：配置 WSL2 内存限制 ====================
echo [2/8] 配置 WSL2 内存限制 ...
set "WSLCONFIG=%USERPROFILE%\.wslconfig"
if not exist "%WSLCONFIG%" (
    echo [wsl2]> "%WSLCONFIG%"
    echo memory=4GB>> "%WSLCONFIG%"
    echo processors=4>> "%WSLCONFIG%"
    echo swap=2GB>> "%WSLCONFIG%"
    echo   已创建 .wslconfig（4GB 内存 / 4 核 / 2GB swap）
    echo   如需调整，请编辑 %WSLCONFIG%
) else (
    echo   .wslconfig 已存在，跳过
)
echo.

:: ==================== 第3步：开放防火墙端口 ====================
echo [3/8] 配置 Windows 防火墙 ...
netsh advfirewall firewall show rule name="渡屿AI-HTTP" >nul 2>&1
if %errorlevel% neq 0 (
    netsh advfirewall firewall add rule name="渡屿AI-HTTP" dir=in action=allow protocol=tcp localport=80 >nul 2>&1
    echo   已开放 TCP 80 端口
) else (
    echo   TCP 80 端口规则已存在
)
netsh advfirewall firewall show rule name="渡屿AI-HTTPS" >nul 2>&1
if %errorlevel% neq 0 (
    netsh advfirewall firewall add rule name="渡屿AI-HTTPS" dir=in action=allow protocol=tcp localport=443 >nul 2>&1
    echo   已开放 TCP 443 端口
    netsh advfirewall firewall add rule name="渡屿AI-HTTPS-UDP" dir=in action=allow protocol=udp localport=443 >nul 2>&1
    echo   已开放 UDP 443 端口（HTTP/3）
) else (
    echo   TCP/UDP 443 端口规则已存在
)
echo.

:: ==================== 第4步：生成 .env 配置 ====================
echo [4/8] 检查环境变量配置 ...
if not exist ".env" (
    if exist "config\env.example" (
        echo   基于 env.example 生成 .env ...
        copy "config\env.example" ".env" >nul

        :: 生成随机密钥
        for /f %%i in ('powershell -Command "[System.Guid]::NewGuid().ToString('N')"') do set "RAND_MYSQL=%%i"
        for /f %%i in ('powershell -Command "[System.Guid]::NewGuid().ToString('N') + [System.Guid]::NewGuid().ToString('N')"') do set "RAND_SESSION=%%i"
        for /f %%i in ('powershell -Command "[System.Guid]::NewGuid().ToString('N')"') do set "RAND_TOKEN=%%i"
        for /f %%i in ('powershell -Command "'sk-' + [System.Guid]::NewGuid().ToString('N')"') do set "RAND_ANTI=%%i"
        for /f %%i in ('powershell -Command "[System.Guid]::NewGuid().ToString('N')"') do set "RAND_CURSOR=%%i"
        for /f %%i in ('powershell -Command "[System.Guid]::NewGuid().ToString('N')"') do set "RAND_KIRO=%%i"
        for /f %%i in ('powershell -Command "[System.Guid]::NewGuid().ToString('N')"') do set "RAND_RESIN_ADMIN=%%i"
        for /f %%i in ('powershell -Command "[System.Guid]::NewGuid().ToString('N')"') do set "RAND_RESIN_PROXY=%%i"

        :: 替换占位符
        powershell -Command "(Get-Content '.env') -replace 'your_mysql_password_here','!RAND_MYSQL!' -replace 'your_session_secret_here','!RAND_SESSION!' -replace 'your_root_token_here','!RAND_TOKEN!' -replace 'sk-your_antigravity_key_here','!RAND_ANTI!' -replace 'your_cursor_api_auth_token_here','!RAND_CURSOR!' -replace 'your_kiro2api_key_here','!RAND_KIRO!' | Set-Content '.env' -Encoding UTF8"

        echo   .env 已生成，密钥已自动填充随机值
        echo   [重要] 请在部署前检查并修改 .env 中的配置
    ) else (
        echo   [警告] config\env.example 不存在，请手动创建 .env 文件
        pause
        exit /b 1
    )
) else (
    echo   .env 已存在，跳过生成
)

:: 确保 .env 中有域名变量
findstr /c:"MAIN_DOMAIN" .env >nul 2>&1
if %errorlevel% neq 0 (
    echo.>> .env
    echo # --- 域名配置（Caddy 使用） --->> .env
    echo MAIN_DOMAIN=localhost>> .env
    echo REGISTER_DOMAIN=>> .env
    echo # --- Cloudflare Tunnel（可选） --->> .env
    echo CF_TUNNEL_TOKEN=>> .env
    echo   已追加域名配置变量到 .env
)
echo.

:: ==================== 第5步：交互式配置 ====================
echo [5/8] 部署模式选择 ...
echo.
echo   请选择部署模式:
echo     1) 公网 IP + 自动 HTTPS（推荐，需要域名指向本机）
echo     2) Cloudflare Tunnel（无公网 IP，需要 CF Tunnel Token）
echo     3) 仅本地访问（HTTP only，localhost）
echo.
set /p DEPLOY_MODE="  请输入选项 [1/2/3] (默认 1): "
if "%DEPLOY_MODE%"=="" set DEPLOY_MODE=1

if "%DEPLOY_MODE%"=="1" (
    set /p INPUT_DOMAIN="  请输入主域名 (如 chat.example.com): "
    if "!INPUT_DOMAIN!"=="" (
        echo   [错误] 公网模式必须输入域名
        pause
        exit /b 1
    )
    set /p INPUT_REG_DOMAIN="  请输入注册域名 (如 register.example.com，留空跳过): "

    :: 更新 .env 中的域名
    powershell -Command "(Get-Content '.env') -replace '^MAIN_DOMAIN=.*','MAIN_DOMAIN=!INPUT_DOMAIN!' | Set-Content '.env' -Encoding UTF8"
    if not "!INPUT_REG_DOMAIN!"=="" (
        powershell -Command "(Get-Content '.env') -replace '^REGISTER_DOMAIN=.*','REGISTER_DOMAIN=!INPUT_REG_DOMAIN!' | Set-Content '.env' -Encoding UTF8"
    )

    :: 使用生产 Caddyfile
    copy /y Caddyfile Caddyfile.active >nul 2>&1
    echo   模式: 公网 HTTPS — !INPUT_DOMAIN!
) else if "%DEPLOY_MODE%"=="2" (
    set /p INPUT_DOMAIN="  请输入主域名 (如 chat.example.com): "
    set /p CF_TOKEN="  请输入 Cloudflare Tunnel Token: "
    if "!CF_TOKEN!"=="" (
        echo   [错误] Tunnel 模式必须输入 CF Token
        pause
        exit /b 1
    )

    powershell -Command "(Get-Content '.env') -replace '^MAIN_DOMAIN=.*','MAIN_DOMAIN=!INPUT_DOMAIN!' -replace '^CF_TUNNEL_TOKEN=.*','CF_TUNNEL_TOKEN=!CF_TOKEN!' | Set-Content '.env' -Encoding UTF8"

    :: 使用本地 Caddyfile
    copy /y Caddyfile.local Caddyfile.active >nul 2>&1
    echo   模式: Cloudflare Tunnel — !INPUT_DOMAIN!
) else (
    powershell -Command "(Get-Content '.env') -replace '^MAIN_DOMAIN=.*','MAIN_DOMAIN=localhost' | Set-Content '.env' -Encoding UTF8"

    :: 使用本地 Caddyfile
    copy /y Caddyfile.local Caddyfile.active >nul 2>&1
    echo   模式: 仅本地访问
)
echo.

:: ==================== 第6步：创建数据目录 ====================
echo [6/8] 创建数据目录结构 ...
for %%d in (
    data\antigravity
    data\cliproxyapi\auth
    data\cliproxyapi\data
    data\cursor-api
    data\cursor-register
    data\gpt-register\output
    data\kirocli2api
    data\copilot-api
    data\resin\cache
    data\resin\state
    data\resin\log
) do (
    if not exist "%%d" (
        mkdir "%%d" 2>nul
        echo   创建 %%d
    )
)
echo   数据目录就绪 ✓
echo.

:: ==================== 第7步：构建与启动服务 ====================
echo [7/8] 构建并启动服务 ...

:: 构建本地镜像
echo   构建本地镜像（kirocli2api, codex-proxy, gpt-register, cursor-register）...
docker compose -f docker-compose.reverse.yml build --parallel 2>&1 | findstr /v "^$"
if %errorlevel% neq 0 (
    echo   [警告] 部分镜像构建失败，继续部署...
)

:: 构建 Caddy 镜像
echo   构建 Caddy 自定义镜像...
docker compose -f docker-compose.caddy.yml build 2>&1 | findstr /v "^$"

:: 启动核心服务
echo   启动核心服务（MySQL + Redis + New API）...
docker compose -f docker-compose.yml up -d
echo   等待 MySQL 健康检查通过（最多 60 秒）...
set /a count=0
:wait_mysql
if !count! geq 12 (
    echo   [警告] MySQL 健康检查超时，继续部署...
    goto mysql_done
)
timeout /t 5 /nobreak >nul
docker inspect --format="{{.State.Health.Status}}" api-mysql 2>nul | findstr "healthy" >nul
if %errorlevel% neq 0 (
    set /a count+=1
    echo     等待 MySQL... (!count!/12)
    goto wait_mysql
)
echo   MySQL 已就绪 ✓
:mysql_done

:: 启动反向代理层
echo   启动逆向代理层...
docker compose -f docker-compose.reverse.yml up -d

:: 启动 Caddy
echo   启动 Caddy 反向代理...
:: 使用 active Caddyfile
if exist "Caddyfile.active" (
    copy /y Caddyfile.active Caddyfile.deploy >nul 2>&1
    docker compose -f docker-compose.caddy.yml up -d
) else (
    docker compose -f docker-compose.caddy.yml up -d
)

:: 可选：启动 Cloudflare Tunnel
if "%DEPLOY_MODE%"=="2" (
    echo   启动 Cloudflare Tunnel...
    docker compose -f docker-compose.tunnel.yml up -d
)
echo.

:: ==================== 第8步：健康检查与摘要 ====================
echo [8/8] 部署完成，执行健康检查 ...
echo.
timeout /t 10 /nobreak >nul

echo  ┌──────────────────────────────────────────┐
echo  │           容器运行状态                     │
echo  └──────────────────────────────────────────┘
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>nul
echo.

:: 读取域名
for /f "tokens=1,* delims==" %%a in ('findstr "^MAIN_DOMAIN=" .env') do set "SHOW_DOMAIN=%%b"
for /f "tokens=1,* delims==" %%a in ('findstr "^REGISTER_DOMAIN=" .env') do set "SHOW_REG_DOMAIN=%%b"

echo  ┌──────────────────────────────────────────┐
echo  │           访问地址                         │
echo  └──────────────────────────────────────────┘
if "%DEPLOY_MODE%"=="3" (
    echo   管理面板:   http://localhost
    echo   Chat UI:    http://localhost/chat/
    echo   API 端点:   http://localhost/v1/
) else if "%DEPLOY_MODE%"=="1" (
    echo   管理面板:   https://!SHOW_DOMAIN!
    echo   Chat UI:    https://!SHOW_DOMAIN!/chat/
    echo   API 端点:   https://!SHOW_DOMAIN!/v1/
    echo   Resin:      https://!SHOW_DOMAIN!/resin/
    echo   Antigravity: https://!SHOW_DOMAIN!/antigravity/
    if not "!SHOW_REG_DOMAIN!"=="" (
        echo   注册面板:   https://!SHOW_REG_DOMAIN!
    )
) else (
    echo   管理面板:   https://!SHOW_DOMAIN!  (通过 CF Tunnel)
    echo   Chat UI:    https://!SHOW_DOMAIN!/chat/
    echo   API 端点:   https://!SHOW_DOMAIN!/v1/
)
echo.
echo  ┌──────────────────────────────────────────┐
echo  │           管理命令                         │
echo  └──────────────────────────────────────────┘
echo   查看状态:   manage.bat status
echo   查看日志:   manage.bat logs [服务名]
echo   重启服务:   manage.bat restart
echo   停止服务:   manage.bat stop
echo.
echo  部署完成！
echo.
pause
