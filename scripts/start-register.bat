@echo off
chcp 65001 >nul
REM ============================================================
REM cursor-auto-register 本地一键启动脚本（Windows + Edge）
REM 使用半自动模式（WEB）：无需域名，通过 Web 界面手动输入验证码
REM ============================================================

echo.
echo   ╔══════════════════════════════════════════╗
echo   ║  Cursor 自动注册服务 - 本地启动          ║
echo   ╚══════════════════════════════════════════╝
echo.

REM 切换到 cursor-auto-register 目录
cd /d "%~dp0..\tools\cursor-auto-register"

REM 检查 Python
python --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Python 未安装，请先安装 Python 3.10+
    pause
    exit /b 1
)
echo [OK] Python 已安装

REM 检查并安装依赖
if not exist ".venv" (
    echo [INFO] 正在创建虚拟环境...
    python -m venv .venv
)

echo [INFO] 正在激活虚拟环境并安装依赖...
call .venv\Scripts\activate.bat
pip install -r requirements.txt -q

REM 检查 .env 文件
if not exist ".env" (
    echo [INFO] 正在创建 .env 配置文件（WEB 半自动模式）...
    (
        echo # 浏览器配置 - 使用 Edge
        echo BROWSER_PATH=C:\Program Files ^(x86^)\Microsoft\Edge\Application\msedge.exe
        echo BROWSER_HEADLESS=False
        echo DYNAMIC_USERAGENT=True
        echo.
        echo # 邮箱配置 - WEB 模式（手动输入验证码，无需域名）
        echo EMAIL_TYPE=tempemail
        echo EMAIL_DOMAINS=tempmail.plus
        echo EMAIL_USERNAME=temp
        echo EMAIL_PIN=
        echo EMAIL_CODE_TYPE=WEB
        echo.
        echo # 账号管理
        echo MAX_ACCOUNTS=10
        echo.
        echo # API 服务
        echo API_HOST=127.0.0.1
        echo API_PORT=9010
        echo API_DEBUG=True
        echo API_WORKERS=1
        echo.
        echo # 数据库
        echo DATABASE_URL=sqlite+aiosqlite:///./accounts.db
    ) > .env
    echo [OK] .env 文件已创建
) else (
    echo [OK] .env 文件已存在
)

echo.
echo ============================================
echo   服务即将启动
echo ============================================
echo.
echo   管理面板: http://127.0.0.1:9010
echo   API 文档: http://127.0.0.1:9010/docs
echo.
echo   使用流程（WEB 半自动模式）:
echo     1. 打开管理面板 http://127.0.0.1:9010
echo     2. 点击"自定义邮箱注册"
echo     3. 输入一个临时邮箱地址（如从 tempmail.plus 获取）
echo     4. 等待浏览器自动填写注册表单
echo     5. 在管理面板"待验证"页面输入收到的验证码
echo     6. 系统自动完成注册并提取 Token
echo.
echo   按 Ctrl+C 停止服务
echo ============================================
echo.

REM 启动服务
python api.py
pause
